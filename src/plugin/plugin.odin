package plugin

import "base:runtime"

import clap "proj:clap-odin"
import "proj:src/dsp"

// Phase 0 skeleton: a validating CLAP plugin with stereo ports, one parameter, and
// state save/load. The gain parameter is a placeholder that proves the whole
// host -> event -> DSP path works; Phase 1 replaces it with the real parameter table.

Multicomp :: struct {
	// Must stay first. The host only ever holds a ^clap.Plugin, and we cast back to
	// this struct through plugin_data.
	plugin:      clap.Plugin,
	host:        ^clap.Host,
	sample_rate: f64,

	// Placeholder parameter state, replaced in Phase 1.
	gain_db:     f64,
}

// Recover our own struct from the pointer the host handed back.
from_plugin :: proc "contextless" (plugin: ^clap.Plugin) -> ^Multicomp {
	return (^Multicomp)(plugin.plugin_data)
}

init :: proc "c" (plugin: ^clap.Plugin) -> bool {
	return true
}

destroy :: proc "c" (plugin: ^clap.Plugin) {
	context = runtime.default_context()
	free(from_plugin(plugin))
}

activate :: proc "c" (plugin: ^clap.Plugin, sample_rate: f64, min_frames, max_frames: u32) -> bool {
	self := from_plugin(plugin)
	self.sample_rate = sample_rate
	return true
}

deactivate :: proc "c" (plugin: ^clap.Plugin) {}

start_processing :: proc "c" (plugin: ^clap.Plugin) -> bool {
	return true
}

stop_processing :: proc "c" (plugin: ^clap.Plugin) {}

reset :: proc "c" (plugin: ^clap.Plugin) {}

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

		block_end := process.frames_count
		if next_event < event_count {
			header := process.in_events.get(process.in_events, next_event)
			block_end = min(header.time, process.frames_count)
		}

		gain := f32(dsp.db_to_linear(self.gain_db))
		input := &process.audio_inputs[0]
		output := &process.audio_outputs[0]

		for channel in 0 ..< input.channel_count {
			src := input.data32[channel]
			dst := output.data32[channel]
			for i in frame ..< block_end {
				dst[i] = src[i] * gain
			}
		}

		frame = block_end
	}

	return .CONTINUE
}

handle_event :: proc "contextless" (self: ^Multicomp, header: ^clap.Event_Header) {
	if header.space_id != clap.CORE_EVENT_SPACE_ID {
		return
	}

	#partial switch clap.Event_Type(header.type) {
	case .PARAM_VALUE:
		event := (^clap.Event_Param_Value)(header)
		if event.param_id == u32(Param_Id.Gain) {
			self.gain_db = event.value
		}
	}
}

on_main_thread :: proc "c" (plugin: ^clap.Plugin) {}
