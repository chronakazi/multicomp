package plugin

import "base:intrinsics"
import "base:runtime"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"
import "proj:src/dsp"

// Phase 3: the compressor is live. Events are applied sample-accurately, gain staging is
// smoothed, and lookahead is delayed with the latency reported to the host.
//
// Not yet live (Phase 4): sidechain routing and filtering, variable stereo link, mid-side,
// mix, auto-makeup and auto-release. Detection is fully linked across channels, which is
// what Stereo Link = 100% (the default) means.

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

	// Lookahead. `latency_samples` is fixed for the lifetime of one activation, because
	// CLAP requires reported latency to stay constant while active.
	lookahead:         [MAX_CHANNELS]dsp.Delay_Line,
	lookahead_storage: []f64,
	latency_samples:   u32,
	latency_dirty:     bool,
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
		dsp.band_init(&self.bands[index], sample_rate)
	}

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

	dsp.envelope_set_times(
		&band.envelope,
		self.values[.Attack],
		self.values[.Release],
		self.sample_rate,
	)

	band.detector.mode = dsp.Detector_Mode(int(self.values[.Detector]))
	band.topology = dsp.Topology_Mode(int(self.values[.Topology]))

	for stage in Gain_Stage {
		dsp.smoother_set_target(&self.gains[stage], gain_target(self, stage))
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

	for i in start ..< end {
		// Gain stages advance every sample so a knob move never steps the output.
		input_trim := dsp.db_to_linear(dsp.smoother_tick(&self.gains[.Input_Trim]))
		makeup_db := dsp.smoother_tick(&self.gains[.Makeup])
		output_trim := dsp.db_to_linear(dsp.smoother_tick(&self.gains[.Output_Trim]))

		// One detector fed by the loudest channel: compressing channels independently
		// would pull the stereo image around on every transient.
		detector_level := 0.0
		for channel in 0 ..< channels {
			sample := f64(input.data32[channel][i]) * input_trim
			detector_level = max(detector_level, abs(sample))
		}

		gain_db := dsp.band_tick(band, detector_level)
		gain := dsp.db_to_linear(gain_db + makeup_db) * input_trim * output_trim

		for channel in 0 ..< channels {
			// The delay line holds the untouched input, so bypass can pass it straight
			// through while still costing the same latency the host was told about.
			delayed := dsp.delay_line_tick(
				&self.lookahead[channel],
				f64(input.data32[channel][i]),
			)
			output.data32[channel][i] = f32(bypassed ? delayed : delayed * gain)
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
