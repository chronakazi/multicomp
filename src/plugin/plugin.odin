package plugin

import "base:intrinsics"
import "base:runtime"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"
import "proj:src/dsp"

// The compressor. Events are applied sample-accurately, gain staging is smoothed, and the
// signal path runs: sidechain selection -> mid/side encode -> high-pass -> detection ->
// static curve -> envelope -> gain, blended back against the latency-aligned dry signal.
//
// Every parameter in the table is live as of Phase 4.

MAX_BANDS :: 4
MAX_CHANNELS :: 2
MAX_LOOKAHEAD_MS :: 10.0

// Gain stages that sit outside the compressor's own envelope and so need their own
// smoothing. Threshold, ratio and knee deliberately do not: a change to the curve reaches
// the output through the envelope follower, which is already smoothing at the attack and
// release times the user asked for.
Gain_Stage :: enum {
	Input_Trim,
	Makeup,
	Output_Trim,
}

GAIN_SMOOTHING_MS :: 20.0

Multicomp :: struct {
	// Must stay first. The host only ever holds a ^clap.Plugin, and we cast back to
	// this struct through plugin_data.
	plugin:            clap.Plugin,
	host:              ^clap.Host,
	host_latency:      ^ext.Host_Latency,
	sample_rate:       f64,

	// Current value of every parameter, indexed by Param_Id.
	values:            [Param_Id]f64,

	// The multiband seam: a fixed array plus a count, so growing to several bands needs
	// no allocation on the audio thread. Phase 3 uses exactly one.
	bands:             [MAX_BANDS]dsp.Compressor_Band,
	band_count:        int,
	gains:             [Gain_Stage]dsp.Smoother,

	// Sidechain conditioning. Lives here rather than in the band because it is routing:
	// SC Listen needs to monitor the filtered signal before the compressor sees it.
	sidechain_filter:  [MAX_CHANNELS]dsp.Biquad,

	// Lookahead. `latency_samples` is fixed for the lifetime of one activation, because
	// CLAP requires reported latency to stay constant while active.
	lookahead:         [MAX_CHANNELS]dsp.Delay_Line,
	lookahead_storage: []f64,
	latency_samples:   u32,
	latency_dirty:     bool,

	// Derived values recomputed only when their inputs change, so a heavily automated
	// block does not pay for exp() and trig on every event boundary.
	auto_makeup_db:    f64,
	cached:            Derived_Config,
}

// The parameter values the expensive coefficient updates depend on.
Derived_Config :: struct {
	attack:            f64,
	release:           f64,
	auto_release:      f64,
	sidechain_cutoff:  f64,
	valid:             bool,
}

// Recover our own struct from the pointer the host handed back.
from_plugin :: proc "contextless" (plugin: ^clap.Plugin) -> ^Multicomp {
	return (^Multicomp)(plugin.plugin_data)
}

reset_to_defaults :: proc "contextless" (self: ^Multicomp) {
	for param, id in PARAMS {
		self.values[id] = param.default
	}
}

// Lookahead expressed in samples at the current sample rate.
lookahead_samples :: proc "contextless" (self: ^Multicomp) -> u32 {
	if self.sample_rate <= 0 {
		return 0
	}
	return u32(self.values[.Lookahead] / 1000 * self.sample_rate + 0.5)
}

init :: proc "c" (plugin: ^clap.Plugin) -> bool {
	context = runtime.default_context()
	self := from_plugin(plugin)

	// Host extensions may only be queried from init onwards.
	if self.host != nil && self.host.get_extension != nil {
		self.host_latency = (^ext.Host_Latency)(
			self.host.get_extension(self.host, ext.EXT_LATENCY),
		)
	}
	return true
}

destroy :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	self := from_plugin(plugin)
	delete(self.lookahead_storage)
	free(self)
}

// [main-thread & !active] - CLAP explicitly permits allocation here.
activate :: proc "c" (plugin: ^clap.Plugin, sample_rate: f64, min_frames, max_frames: u32) -> bool {
	context = runtime.default_context()
	self := from_plugin(plugin)
	self.sample_rate = sample_rate

	// Size for the maximum lookahead so the buffer never has to grow while active.
	per_channel := int(MAX_LOOKAHEAD_MS / 1000 * sample_rate) + 2
	delete(self.lookahead_storage)
	self.lookahead_storage = make([]f64, per_channel * MAX_CHANNELS)

	for channel in 0 ..< MAX_CHANNELS {
		start := channel * per_channel
		dsp.delay_line_init(&self.lookahead[channel], self.lookahead_storage[start:][:per_channel])
	}

	// Latency is latched here and must not change until the next activation.
	self.latency_samples = lookahead_samples(self)
	intrinsics.atomic_store_explicit(&self.latency_dirty, false, .Relaxed)

	self.band_count = 1
	for index in 0 ..< self.band_count {
		dsp.band_init(&self.bands[index], sample_rate, MAX_CHANNELS)
	}
	self.cached = {}

	for stage in Gain_Stage {
		dsp.smoother_init(
			&self.gains[stage],
			GAIN_SMOOTHING_MS,
			sample_rate,
			gain_target(self, stage),
		)
	}

	reset(plugin)
	return true
}

deactivate :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	self := from_plugin(plugin)
	delete(self.lookahead_storage)
	self.lookahead_storage = nil
}

start_processing :: proc "c" (plugin: ^clap.Plugin) -> bool {
	return true
}

stop_processing :: proc "c" (plugin: ^clap.Plugin) {}

// Clears every buffer and kills the envelope, without touching parameter values.
reset :: proc "c" (plugin: ^clap.Plugin) {
	self := from_plugin(plugin)

	for index in 0 ..< self.band_count {
		dsp.band_reset(&self.bands[index])
	}
	for channel in 0 ..< MAX_CHANNELS {
		dsp.delay_line_clear(&self.lookahead[channel])
		dsp.delay_line_set_delay(&self.lookahead[channel], int(self.latency_samples))
		dsp.biquad_reset(&self.sidechain_filter[channel])
	}
	for stage in Gain_Stage {
		dsp.smoother_snap(&self.gains[stage], gain_target(self, stage))
	}
	sync_dsp(self)
}

gain_target :: proc "contextless" (self: ^Multicomp, stage: Gain_Stage) -> f64 {
	switch stage {
	case .Input_Trim:
		return self.values[.Input_Trim]
	case .Makeup:
		return self.values[.Makeup]
	case .Output_Trim:
		return self.values[.Output_Trim]
	}
	return 0
}

// Pushes parameter values into the DSP. Called at every event boundary, so a change lands
// on exactly the sample the host asked for.
sync_dsp :: proc "contextless" (self: ^Multicomp) {
	band := &self.bands[0]

	threshold := self.values[.Threshold]
	knee := self.values[.Knee]
	ratio := self.values[.Ratio]
	if ratio >= RATIO_MAX {
		dsp.gain_computer_set_limiting(&band.computer, threshold, knee)
	} else {
		dsp.gain_computer_set(&band.computer, threshold, ratio, knee)
	}

	// Auto makeup restores half of what the curve would take off a full-scale signal.
	// Half rather than all: full compensation reliably overshoots, because real material
	// does not sit at 0 dBFS. At 1:1 this is 0, so the default stays transparent.
	self.auto_makeup_db = 0.5 * dsp.gain_computer_reduction_db(band.computer, 0)

	band_set_detector(self, dsp.Detector_Mode(int(self.values[.Detector])))
	band.topology = dsp.Topology_Mode(int(self.values[.Topology]))
	band.stereo_link = self.values[.Stereo_Link] * 0.01

	// Coefficient updates involve exp() and trig, so only redo them when their inputs
	// actually moved. Automation can otherwise land an event on every sample.
	attack := self.values[.Attack]
	release := self.values[.Release]
	auto_release := self.values[.Auto_Release]
	cutoff := self.values[.Sidechain_Highpass]

	if !self.cached.valid ||
	   self.cached.attack != attack ||
	   self.cached.release != release ||
	   self.cached.auto_release != auto_release {
		dsp.band_set_times(band, attack, release, self.sample_rate, auto_release >= 0.5)
		self.cached.attack = attack
		self.cached.release = release
		self.cached.auto_release = auto_release
	}

	if !self.cached.valid || self.cached.sidechain_cutoff != cutoff {
		for channel in 0 ..< MAX_CHANNELS {
			// The bottom of the range means "off", so the default detector path is
			// genuinely unfiltered rather than merely nearly so.
			if cutoff <= SIDECHAIN_HIGHPASS_MIN {
				dsp.biquad_set_bypass(&self.sidechain_filter[channel])
			} else {
				dsp.biquad_set_highpass(
					&self.sidechain_filter[channel],
					cutoff,
					dsp.BUTTERWORTH_Q,
					self.sample_rate,
				)
			}
		}
		self.cached.sidechain_cutoff = cutoff
	}

	self.cached.valid = true

	for stage in Gain_Stage {
		dsp.smoother_set_target(&self.gains[stage], gain_target(self, stage))
	}
}

band_set_detector :: proc "contextless" (self: ^Multicomp, mode: dsp.Detector_Mode) {
	for index in 0 ..< self.band_count {
		dsp.band_set_detector(&self.bands[index], mode)
	}
}

// No `context` is set anywhere in this call tree, on purpose: it makes any allocating
// call a compile error, which is exactly the guarantee the audio thread needs.
process :: proc "c" (plugin: ^clap.Plugin, process: ^clap.Process) -> clap.Process_Status {
	self := from_plugin(plugin)

	event_count := process.in_events.size(process.in_events)
	next_event: u32 = 0
	frame: u32 = 0

	// Split the block at every event boundary so parameter changes land on the exact
	// sample the host asked for, rather than all at once at the start of the block.
	for frame < process.frames_count {
		for next_event < event_count {
			header := process.in_events.get(process.in_events, next_event)
			if header.time > frame {
				break
			}
			handle_event(self, header)
			next_event += 1
		}
		sync_dsp(self)

		block_end := process.frames_count
		if next_event < event_count {
			header := process.in_events.get(process.in_events, next_event)
			block_end = min(header.time, process.frames_count)
		}

		process_block(self, process, frame, block_end)
		frame = block_end
	}

	return .CONTINUE
}

process_block :: proc "contextless" (self: ^Multicomp, process: ^clap.Process, start, end: u32) {
	input := &process.audio_inputs[0]
	output := &process.audio_outputs[0]
	if input.data32 == nil || output.data32 == nil {
		return
	}

	channels := min(int(input.channel_count), int(output.channel_count), MAX_CHANNELS)
	band := &self.bands[0]

	bypassed := self.values[.Bypass] >= 0.5
	mid_side := int(self.values[.Channel_Mode]) == int(Channel_Mode_Value.Mid_Side)
	listening := self.values[.Sidechain_Listen] >= 0.5
	mix := clamp(self.values[.Mix] * 0.01, 0, 1)

	auto_makeup := self.values[.Auto_Makeup] >= 0.5 ? self.auto_makeup_db : 0

	// Fall back to the main input when the host has not connected a sidechain, so
	// selecting External never silently mutes the detector.
	detector_source := input
	if int(self.values[.Sidechain_Source]) == int(Sidechain_Source_Value.External) &&
	   process.audio_inputs_count > SIDECHAIN_PORT {
		candidate := &process.audio_inputs[SIDECHAIN_PORT]
		if candidate.data32 != nil && candidate.channel_count > 0 {
			detector_source = candidate
		}
	}
	source_channels := int(detector_source.channel_count)

	for i in start ..< end {
		// Gain stages advance every sample so a knob move never steps the output.
		input_trim := dsp.db_to_linear(dsp.smoother_tick(&self.gains[.Input_Trim]))
		makeup_db := dsp.smoother_tick(&self.gains[.Makeup]) + auto_makeup
		output_trim := dsp.db_to_linear(dsp.smoother_tick(&self.gains[.Output_Trim]))

		// --- detector path -------------------------------------------------------
		detector: [MAX_CHANNELS]f64
		for channel in 0 ..< channels {
			source := min(channel, source_channels - 1)
			detector[channel] = f64(detector_source.data32[source][i]) * input_trim
		}
		if mid_side && channels >= 2 {
			detector[0], detector[1] = dsp.encode_mid_side(detector[0], detector[1])
		}
		for channel in 0 ..< channels {
			detector[channel] = dsp.biquad_tick(
				&self.sidechain_filter[channel],
				detector[channel],
			)
		}

		gains_db: [MAX_CHANNELS]f64
		dsp.band_tick(band, detector[:channels], gains_db[:channels])

		// --- signal path ---------------------------------------------------------
		// The delay line holds the untouched input, so bypass can pass it straight
		// through while still costing the same latency the host was told about.
		dry: [MAX_CHANNELS]f64
		for channel in 0 ..< channels {
			dry[channel] = dsp.delay_line_tick(
				&self.lookahead[channel],
				f64(input.data32[channel][i]),
			)
		}

		if bypassed {
			for channel in 0 ..< channels {
				output.data32[channel][i] = f32(dry[channel])
			}
			continue
		}

		// Auditioning the detector: hear exactly what the compressor is reacting to.
		if listening {
			for channel in 0 ..< channels {
				output.data32[channel][i] = f32(detector[channel] * output_trim)
			}
			continue
		}

		for channel in 0 ..< channels {
			dry[channel] *= input_trim
		}

		wet := dry
		if mid_side && channels >= 2 {
			wet[0], wet[1] = dsp.encode_mid_side(wet[0], wet[1])
		}
		for channel in 0 ..< channels {
			wet[channel] *= dsp.db_to_linear(gains_db[channel] + makeup_db)
		}
		if mid_side && channels >= 2 {
			wet[0], wet[1] = dsp.decode_mid_side(wet[0], wet[1])
		}

		// Parallel compression. Both paths come off the same delay line, so the dry
		// signal is already latency-aligned with the wet one - blending them cannot
		// produce the comb filtering that an uncompensated dry path would.
		for channel in 0 ..< channels {
			blended := dry[channel] + (wet[channel] - dry[channel]) * mix
			output.data32[channel][i] = f32(blended * output_trim)
		}
	}
}

handle_event :: proc "contextless" (self: ^Multicomp, header: ^clap.Event_Header) {
	if header.space_id != clap.CORE_EVENT_SPACE_ID {
		return
	}

	#partial switch clap.Event_Type(header.type) {
	case .PARAM_VALUE:
		event := (^clap.Event_Param_Value)(header)
		if !is_valid_param(event.param_id) {
			return
		}
		id := Param_Id(event.param_id)
		self.values[id] = clamp_param(id, event.value)

		if id == .Lookahead {
			request_latency_update(self)
		}
	}
}

// CLAP requires reported latency to stay constant while the plugin is active, so a
// lookahead change cannot take effect immediately. Flag it and ask the host for a main
// thread callback, where we can announce the change and request a restart.
request_latency_update :: proc "contextless" (self: ^Multicomp) {
	if lookahead_samples(self) == self.latency_samples {
		return
	}
	intrinsics.atomic_store_explicit(&self.latency_dirty, true, .Relaxed)
	if self.host != nil && self.host.request_callback != nil {
		self.host.request_callback(self.host)
	}
}

on_main_thread :: proc "c" (plugin: ^clap.Plugin) {
	self := from_plugin(plugin)
	if !intrinsics.atomic_load_explicit(&self.latency_dirty, .Relaxed) {
		return
	}
	intrinsics.atomic_store_explicit(&self.latency_dirty, false, .Relaxed)

	if self.host_latency != nil && self.host_latency.changed != nil {
		self.host_latency.changed(self.host)
	}
	if self.host != nil && self.host.request_restart != nil {
		self.host.request_restart(self.host)
	}
}
