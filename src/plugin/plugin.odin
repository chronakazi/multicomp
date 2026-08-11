package plugin

import "base:intrinsics"
import "base:runtime"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"
import "proj:src/dsp"
import "proj:src/gui"

// The compressor. Events are applied sample-accurately, gain staging is smoothed, and the
// signal path runs: sidechain selection -> mid/side encode -> high-pass -> detection ->
// static curve -> envelope -> gain, blended back against the latency-aligned dry signal.
//
// Every parameter in the table is live as of Phase 4.

MAX_BANDS :: 4
MAX_CHANNELS :: 2
MAX_LOOKAHEAD_MS :: 10.0

// Everything the user controls that reaches the output without passing through the
// compressor's envelope gets its own smoother, so automation and knob moves ramp instead
// of stepping: the gain trims, makeup (with auto makeup folded in), and the two
// crossfades - bypass and parallel mix. Threshold, ratio and knee deliberately have no
// smoother: a change to the curve reaches the output through the envelope follower,
// which is already smoothing at the attack and release times the user asked for.
Gain_Stage :: enum {
	Input_Trim,
	Makeup,
	Output_Trim,
	Bypass,
	Mix,
}

GAIN_SMOOTHING_MS :: 20.0

Multicomp :: struct {
	// Must stay first. The host only ever holds a ^clap.Plugin, and we cast back to
	// this struct through plugin_data.
	plugin:            clap.Plugin,
	host:              ^clap.Host,
	host_latency:      ^ext.Host_Latency,
	sample_rate:       f64,
	activated:         bool,

	// Current value of every parameter, indexed by Param_Id. Written *only* from
	// process/flush/activate, which CLAP guarantees never overlap - so there is exactly
	// one writer at any moment. Main-thread readers go to `mirror` instead.
	values:            [Param_Id]f64,

	// A state load arrives on the main thread while the audio thread may be mid-block.
	// Writing `values` from there would be a second writer, and a preset could be seen
	// half-applied for a block. The load stages a complete set here instead, and the
	// next process/flush/activate swaps it in whole.
	staged:            [Param_Id]f64,
	staged_pending:    bool,

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
	cached:            Derived_Config,

	// Selected port layout (stereo or mono main ports), from clap.audio-ports-config.
	// The host may only select while the plugin is deactivated.
	port_config:       Port_Config,

	// GUI. Main-thread only, and entirely optional: the plugin processes audio whether or
	// not a window has ever been opened.
	ui:                gui.Gui,
	host_timer:        ^ext.Host_Timer_Support,
	host_params:       ^ext.Host_Params,
	timer_id:          clap.Clap_Id,
	timer_running:     bool,

	// GUI -> audio. Edits cross here, then leave on out_events so the host records them.
	ui_queue:          Ui_Queue,

	// audio -> GUI. f64 bits, written atomically by the audio thread.
	mirror:            [Param_Id]u64,
	meter_in:          u64,
	meter_gr:          u64,
	meter_out:         u64,
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
	publish_values(self)
}

// Mirrors the authoritative values where the GUI can read them without racing the audio
// thread. Cheap enough to do once per block.
//
// Because this runs before process/flush return, and nothing else writes `values`, a
// main-thread reader can never observe the mirror lagging behind: between calls the two
// are identical. That is what makes it safe for get_value and state.save to read.
publish_values :: proc "contextless" (self: ^Multicomp) {
	for _, id in PARAMS {
		publish(&self.mirror[id], self.values[id])
	}
}

// Swaps in a state load that arrived while the audio thread owned `values`. Called from
// the three places allowed to write them - process, flush and activate - none of which
// can overlap, so the set lands whole or not at all.
apply_staged :: proc "contextless" (self: ^Multicomp) {
	if !intrinsics.atomic_load_explicit(&self.staged_pending, .Acquire) {
		return
	}
	for _, id in PARAMS {
		self.values[id] = self.staged[id]
	}
	intrinsics.atomic_store_explicit(&self.staged_pending, false, .Release)
}

// Drains GUI edits, applies them, and echoes them to the host so a knob move is recorded
// as automation. Called from both process() and flush().
drain_ui :: proc "contextless" (self: ^Multicomp, out_events: ^clap.Output_Events) {
	for {
		event, ok := ui_queue_pop(&self.ui_queue)
		if !ok {
			break
		}

		switch event.kind {
		case .Value:
			// A drag enqueues a value per mouse event, faster than blocks drain them.
			// Collapse a run of edits to one control into its newest member - the
			// intermediate points are of no interest to the DSP or the automation lane.
			value := event.value
			for {
				next, more := ui_queue_peek(&self.ui_queue)
				if !more || next.kind != .Value || next.param != event.param {
					break
				}
				value = next.value
				ui_queue_pop(&self.ui_queue)
			}

			if is_valid_param(event.param) {
				id := Param_Id(event.param)
				value = clamp_param(id, value)
				self.values[id] = value
				if id == .Lookahead {
					request_latency_update(self, lookahead_samples(self))
				}
			}
			// Echo the value actually applied, so the host records what the DSP did.
			push_param_value(out_events, event.param, value)

		case .Gesture_Begin:
			if is_valid_param(event.param) {
				push_gesture(out_events, event.param, .PARAM_GESTURE_BEGIN)
			}

		case .Gesture_End:
			if is_valid_param(event.param) {
				push_gesture(out_events, event.param, .PARAM_GESTURE_END)
			}
		}
	}
}

@(private = "file")
push_param_value :: proc "contextless" (
	out_events: ^clap.Output_Events,
	param: clap.Clap_Id,
	value: f64,
) {
	if out_events == nil || out_events.try_push == nil {
		return
	}
	event := clap.Event_Param_Value {
		header = {
			size = size_of(clap.Event_Param_Value),
			time = 0,
			space_id = clap.CORE_EVENT_SPACE_ID,
			type = u16(clap.Event_Type.PARAM_VALUE),
			flags = 0,
		},
		param_id = param,
		cookie = nil,
		note_id = -1,
		port_index = -1,
		channel = -1,
		key = -1,
		value = value,
	}
	out_events.try_push(out_events, &event.header)
}

@(private = "file")
push_gesture :: proc "contextless" (
	out_events: ^clap.Output_Events,
	param: clap.Clap_Id,
	type: clap.Event_Type,
) {
	if out_events == nil || out_events.try_push == nil {
		return
	}
	event := clap.Event_Param_Gesture {
		header = {
			size = size_of(clap.Event_Param_Gesture),
			time = 0,
			space_id = clap.CORE_EVENT_SPACE_ID,
			type = u16(type),
			flags = 0,
		},
		param_id = param,
	}
	out_events.try_push(out_events, &event.header)
}

// Lookahead expressed in samples at the current sample rate.
lookahead_samples :: proc "contextless" (self: ^Multicomp) -> u32 {
	return lookahead_samples_for(self, self.values[.Lookahead])
}

// The same, for a lookahead that has not been applied yet - a state load has to decide
// whether to announce a latency change before its values reach `values`.
lookahead_samples_for :: proc "contextless" (self: ^Multicomp, milliseconds: f64) -> u32 {
	if self.sample_rate <= 0 {
		return 0
	}
	return u32(milliseconds / 1000 * self.sample_rate + 0.5)
}

init :: proc "c" (plugin: ^clap.Plugin) -> bool {
	context = runtime.default_context()
	self := from_plugin(plugin)

	// Host extensions may only be queried from init onwards.
	if self.host != nil && self.host.get_extension != nil {
		self.host_latency = (^ext.Host_Latency)(
			self.host.get_extension(self.host, ext.EXT_LATENCY),
		)
		self.host_timer = (^ext.Host_Timer_Support)(
			self.host.get_extension(self.host, ext.EXT_TIMER_SUPPORT),
		)
		self.host_params = (^ext.Host_Params)(
			self.host.get_extension(self.host, ext.EXT_PARAMS),
		)
	}
	publish_values(self)
	return true
}

destroy :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	self := from_plugin(plugin)
	// A host is supposed to destroy the GUI first. Not all of them do, and a surviving
	// run-loop timer would go on firing into this struct after it is freed.
	gui_teardown(self)
	delete(self.lookahead_storage)
	free(self)
}

// [main-thread & !active] - CLAP explicitly permits allocation here.
activate :: proc "c" (plugin: ^clap.Plugin, sample_rate: f64, min_frames, max_frames: u32) -> bool {
	context = runtime.default_context()
	self := from_plugin(plugin)
	self.sample_rate = sample_rate

	// A state load may have arrived while inactive, with nothing running to pick it up.
	// It has to land before the lookahead below is latched, or latency would be latched
	// from the outgoing preset.
	apply_staged(self)

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

	// Meters are plain atomics that persist across activations; start each one from
	// silence rather than from whatever the last session (or zero initialisation) left.
	publish(&self.meter_in, dsp.SILENCE_DB)
	publish(&self.meter_out, dsp.SILENCE_DB)
	publish(&self.meter_gr, 0)

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
	self.activated = true
	return true
}

deactivate :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	self := from_plugin(plugin)
	self.activated = false
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

// The static curve for given settings, with the top of the ratio range mapped to
// limiting. Shared by sync_dsp, the auto-makeup target and the GUI's transfer window,
// so what is displayed, applied and compensated for can never disagree.
make_curve :: proc "contextless" (threshold, ratio, knee: f64) -> dsp.Gain_Computer {
	computer: dsp.Gain_Computer
	if ratio >= RATIO_MAX {
		dsp.gain_computer_set_limiting(&computer, threshold, knee)
	} else {
		dsp.gain_computer_set(&computer, threshold, ratio, knee)
	}
	return computer
}

// The curve as configured by the current parameter values.
curve_from_values :: proc "contextless" (self: ^Multicomp) -> dsp.Gain_Computer {
	return make_curve(self.values[.Threshold], self.values[.Ratio], self.values[.Knee])
}

gain_target :: proc "contextless" (self: ^Multicomp, stage: Gain_Stage) -> f64 {
	switch stage {
	case .Input_Trim:
		return self.values[.Input_Trim]
	case .Makeup:
		// Auto makeup restores half of what the curve would take off a full-scale
		// signal. Half rather than all: full compensation reliably overshoots, because
		// real material does not sit at 0 dBFS. At 1:1 this is 0, so the default stays
		// transparent. It is folded into the smoother target rather than added after
		// the smoother, so automating the curve with auto makeup on ramps the
		// compensation instead of stepping it.
		makeup := self.values[.Makeup]
		if self.values[.Auto_Makeup] >= 0.5 {
			computer := curve_from_values(self)
			makeup += 0.5 * dsp.gain_computer_reduction_db(computer, 0)
		}
		return makeup
	case .Output_Trim:
		return self.values[.Output_Trim]
	case .Bypass:
		return self.values[.Bypass] >= 0.5 ? 1 : 0
	case .Mix:
		return clamp(self.values[.Mix] * 0.01, 0, 1)
	}
	return 0
}

// Pushes parameter values into the DSP. Called at every event boundary, so a change lands
// on exactly the sample the host asked for.
//
// Today every band shares one global parameter set, so the same values are pushed to all
// of them. When bands gain their own parameter pages this becomes a per-band lookup; the
// loop and the coefficient caching below stay as they are.
sync_dsp :: proc "contextless" (self: ^Multicomp) {
	topology := dsp.Topology_Mode(int(self.values[.Topology]))
	stereo_link := self.values[.Stereo_Link] * 0.01

	curve := curve_from_values(self)
	for index in 0 ..< self.band_count {
		band := &self.bands[index]
		band.computer = curve
		band.topology = topology
		band.stereo_link = stereo_link
	}

	band_set_detector(self, dsp.Detector_Mode(int(self.values[.Detector])))

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
		for index in 0 ..< self.band_count {
			dsp.band_set_times(&self.bands[index], attack, release, self.sample_rate, auto_release >= 0.5)
		}
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

	// A preset that landed since the last block, swapped in whole before anything reads
	// a parameter - so no block ever runs on a mixture of two states.
	apply_staged(self)

	// GUI edits first, so a knob move applies to this block rather than the next one.
	drain_ui(self, process.out_events)

	event_count := process.in_events.size(process.in_events)
	next_event: u32 = 0
	frame: u32 = 0
	peak_in, peak_out, gr_peak := 0.0, 0.0, 0.0

	// Split the block at every event boundary so parameter changes land on the exact
	// sample the host asked for, rather than all at once at the start of the block.
	for frame < process.frames_count {
		for next_event < event_count {
			header := process.in_events.get(process.in_events, next_event)
			if header == nil {
				next_event += 1 // a sloppy host handed us a hole; skip it
				continue
			}
			if header.time > frame {
				break
			}
			handle_event(self, header)
			next_event += 1
		}
		sync_dsp(self)

		block_end := process.frames_count
		if next_event < event_count {
			// nil here just means the rest of the list is unusable; run to the end.
			if header := process.in_events.get(process.in_events, next_event); header != nil {
				block_end = min(header.time, process.frames_count)
			}
		}

		block_in, block_out, block_gr := process_block(self, process, frame, block_end)
		peak_in = max(peak_in, block_in)
		peak_out = max(peak_out, block_out)
		gr_peak = max(gr_peak, block_gr)
		frame = block_end
	}

	// Anything the loop above did not reach still has to be applied: an event stamped
	// past the end of the block, or - since the loop runs zero times - every event in a
	// zero-length one. Dropping them would silently lose a parameter change, and the
	// host has no way to tell. They land at the end of the block, which is the closest
	// sample to where they were asked for.
	for next_event < event_count {
		if header := process.in_events.get(process.in_events, next_event); header != nil {
			handle_event(self, header)
		}
		next_event += 1
	}

	publish_meters(self, peak_in, peak_out, gr_peak, f64(process.frames_count))
	publish_values(self)
	return .CONTINUE
}

// Meter ballistics: rise instantly, fall at a fixed rate in dB per second.
//
// Expressing the fall per second rather than per block matters — the previous version
// decayed a fixed amount each call, so the meters fell roughly eight times faster at a
// 64-sample buffer than at 512, and the same plugin metered differently depending on the
// host's buffer setting.
METER_FALL_DB_PER_SEC :: 20.0
GR_FALL_DB_PER_SEC :: 36.0

publish_meters :: proc "contextless" (self: ^Multicomp, peak_in, peak_out, gr, frames: f64) {
	seconds := self.sample_rate > 0 ? frames / self.sample_rate : 0

	// gr is the deepest reduction applied anywhere in the block. Reading only the final
	// sample's gain would miss a transient that attacked and recovered inside one large
	// buffer. The GR meter falls back toward 0, so its floor is 0 rather than silence.
	decay_toward(&self.meter_gr, gr, GR_FALL_DB_PER_SEC * seconds, 0)

	fall := METER_FALL_DB_PER_SEC * seconds
	decay_toward(&self.meter_in, dsp.linear_to_db(peak_in), fall, dsp.SILENCE_DB)
	decay_toward(&self.meter_out, dsp.linear_to_db(peak_out), fall, dsp.SILENCE_DB)
}

@(private = "file")
decay_toward :: proc "contextless" (slot: ^u64, value, fall, floor: f64) {
	previous := read_published(slot)
	publish(slot, max(value, max(previous - fall, floor)))
}

// Returns the peak input and output magnitudes over the block plus the deepest gain
// reduction applied, for metering. The input figure is taken after the trim, because
// that is the level the threshold is compared against — and therefore the x axis of the
// transfer window.
process_block :: proc "contextless" (
	self: ^Multicomp,
	process: ^clap.Process,
	start, end: u32,
) -> (peak_in: f64, peak_out: f64, gr_peak: f64) {
	// Defensive port handling. CLAP lets a host leave a port disconnected, and some
	// express that by shrinking the port count rather than by nulling the buffer —
	// so the array may be shorter than the port table, or missing entirely.
	if process.audio_outputs == nil || process.audio_outputs_count == 0 {
		return 0, 0, 0
	}
	output := &process.audio_outputs[0]
	if output.data32 == nil || output.channel_count == 0 {
		return 0, 0, 0
	}
	out_channels := min(int(output.channel_count), MAX_CHANNELS)

	input: ^clap.Audio_Buffer
	if process.audio_inputs != nil && process.audio_inputs_count > 0 {
		candidate := &process.audio_inputs[0]
		if candidate.data32 != nil && candidate.channel_count > 0 {
			input = candidate
		}
	}
	if input == nil {
		// No usable input. The output must still be written - leaving it alone would
		// repeat whatever the buffer last held.
		write_silence(output, out_channels, start, end)
		return 0, 0, 0
	}

	channels := min(int(input.channel_count), out_channels)
	band := &self.bands[0]

	mid_side := int(self.values[.Channel_Mode]) == int(Channel_Mode_Value.Mid_Side)
	listening := self.values[.Sidechain_Listen] >= 0.5

	// Fall back to the main input when the host has not connected a sidechain, so
	// selecting External never silently mutes the detector.
	detector_source := input
	external_detector := false
	if int(self.values[.Sidechain_Source]) == int(Sidechain_Source_Value.External) &&
	   process.audio_inputs_count > SIDECHAIN_PORT {
		candidate := &process.audio_inputs[SIDECHAIN_PORT]
		if candidate.data32 != nil && candidate.channel_count > 0 {
			detector_source = candidate
			external_detector = true
		}
	}
	source_channels := int(detector_source.channel_count)

	for i in start ..< end {
		// Gain stages and crossfades advance every sample so a knob move, a bypass
		// toggle or an automation step ramps instead of clicking.
		input_trim := dsp.db_to_linear(dsp.smoother_tick(&self.gains[.Input_Trim]))
		makeup_db := dsp.smoother_tick(&self.gains[.Makeup])
		output_trim := dsp.db_to_linear(dsp.smoother_tick(&self.gains[.Output_Trim]))
		bypass := dsp.smoother_tick(&self.gains[.Bypass])
		mix := dsp.smoother_tick(&self.gains[.Mix])

		// --- detector path -------------------------------------------------------
		// Input trim stages the main path, so the *internal* detector has to see it too:
		// it is the same signal, and the threshold has to keep meaning what the input
		// meter says. An external sidechain arrives at whatever level the host routed to
		// it, and trimming the signal being compressed must not change how hard that
		// source ducks it - the DAW is where the sidechain's own level gets set.
		//
		// This tracks the source actually in use, not the parameter: when External is
		// selected but nothing is patched in, the detector really is the main input and
		// the trim applies again.
		detector_trim := external_detector ? 1 : input_trim

		detector: [MAX_CHANNELS]f64
		for channel in 0 ..< channels {
			source := min(channel, source_channels - 1)
			detector[channel] = f64(detector_source.data32[source][i]) * detector_trim
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
		for channel in 0 ..< channels {
			gr_peak = max(gr_peak, -gains_db[channel])
		}

		// --- signal path ---------------------------------------------------------
		// The delay line holds the untouched input, so bypass can pass it straight
		// through while still costing the same latency the host was told about.
		dry: [MAX_CHANNELS]f64
		for channel in 0 ..< channels {
			raw := f64(input.data32[channel][i])
			peak_in = max(peak_in, abs(raw * input_trim))
			dry[channel] = dsp.delay_line_tick(&self.lookahead[channel], raw)
		}

		// Fully bypassed: pass the delayed input exactly, and skip the wet path. The
		// detector and envelope above keep running, so unbypassing starts warm.
		if bypass >= 1 {
			for channel in 0 ..< channels {
				output.data32[channel][i] = f32(dry[channel])
				peak_out = max(peak_out, abs(dry[channel]))
			}
			continue
		}

		processed: [MAX_CHANNELS]f64
		if listening {
			// Auditioning the detector: hear exactly what the compressor reacts to.
			// In mid-side the detector array is still encoded, so it is decoded back to
			// L/R first - monitoring it raw would put the mid in the left channel and
			// the side in the right, which is not a signal anyone can judge by ear. The
			// filter is linear, so decoding after it yields the filtered L/R exactly.
			monitor := detector
			if mid_side && channels >= 2 {
				monitor[0], monitor[1] = dsp.decode_mid_side(monitor[0], monitor[1])
			}
			for channel in 0 ..< channels {
				processed[channel] = monitor[channel] * output_trim
			}
		} else {
			wet: [MAX_CHANNELS]f64
			for channel in 0 ..< channels {
				wet[channel] = dry[channel] * input_trim
			}
			if mid_side && channels >= 2 {
				wet[0], wet[1] = dsp.encode_mid_side(wet[0], wet[1])
			}
			for channel in 0 ..< channels {
				wet[channel] *= dsp.db_to_linear(gains_db[channel] + makeup_db)
			}
			if mid_side && channels >= 2 {
				wet[0], wet[1] = dsp.decode_mid_side(wet[0], wet[1])
			}

			// Parallel compression. Both paths come off the same delay line, so the
			// dry signal is already latency-aligned with the wet one - blending them
			// cannot produce the comb filtering an uncompensated dry path would.
			for channel in 0 ..< channels {
				trimmed := dry[channel] * input_trim
				processed[channel] = (trimmed + (wet[channel] - trimmed) * mix) * output_trim
			}
		}

		// Bypass is a crossfade, not a switch: an instantaneous jump between two
		// different gains is a waveform discontinuity, audible as a click. The fade
		// target is the untrimmed delayed input - bypassed means untouched.
		for channel in 0 ..< channels {
			value := processed[channel]
			if bypass > 0 {
				value += (dry[channel] - value) * bypass
			}
			output.data32[channel][i] = f32(value)
			peak_out = max(peak_out, abs(value))
		}
	}

	// Channels the input didn't cover (a mono input on our stereo port, say) must not
	// pass stale buffer content through.
	write_silence(output, out_channels, start, end, skip = channels)

	return
}

@(private = "file")
write_silence :: proc "contextless" (
	output: ^clap.Audio_Buffer,
	channels: int,
	start, end: u32,
	skip := 0,
) {
	for channel in skip ..< channels {
		for i in start ..< end {
			output.data32[channel][i] = 0
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
			request_latency_update(self, lookahead_samples(self))
		}
	}
}

// CLAP requires reported latency to stay constant while the plugin is active, so a
// lookahead change cannot take effect immediately. Flag it and ask the host for a main
// thread callback, where we can announce the change and request a restart.
//
// `target` is the latency the new lookahead would produce, passed in rather than read
// back out because a state load has to ask this question before its values are live.
request_latency_update :: proc "contextless" (self: ^Multicomp, target: u32) {
	if target == self.latency_samples {
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
