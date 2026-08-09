package plugin

import "base:runtime"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"

// Extension dispatch. The host asks by string id; we hand back a pointer to a static
// vtable. Returning nil simply means "not supported" and is always safe.
get_extension :: proc "c" (plugin: ^clap.Plugin, id: cstring) -> rawptr {
	// cstring -> string does a strlen, so this must stay off the audio thread.
	// CLAP marks get_extension [thread-safe] but hosts call it from the main thread.
	context = runtime.default_context()

	switch string(id) {
	case ext.EXT_AUDIO_PORTS:
		return &audio_ports_ext
	case ext.EXT_PARAMS:
		return &params_ext
	case ext.EXT_STATE:
		return &state_ext
	case ext.EXT_LATENCY:
		return &latency_ext
	case ext.EXT_TAIL:
		return &tail_ext
	case ext.EXT_GUI:
		return &gui_ext
	case ext.EXT_TIMER_SUPPORT:
		return &timer_ext
	case EXT_METERS:
		return &meters_ext
	}
	return nil
}

//
// Meter readback. Not a CLAP extension - the GUI already reads these atomics through the
// bridge - but an explicit, named interface so the offline tool can assert on metering
// without knowing the plugin's struct layout. It deliberately returns the *published*
// value: what is checked here is what the GUI would show.
//

EXT_METERS :: "com.foesoft.multicomp.meters"

Meter_Kind :: enum i32 {
	Input,
	Gain_Reduction,
	Output,
}

Plugin_Meters :: struct {
	get: proc "c" (plugin: ^clap.Plugin, kind: i32) -> f64,
}

meters_ext := Plugin_Meters {
	get = proc "c" (plugin: ^clap.Plugin, kind: i32) -> f64 {
		self := from_plugin(plugin)
		switch Meter_Kind(kind) {
		case .Input:
			return read_published(&self.meter_in)
		case .Gain_Reduction:
			return read_published(&self.meter_gr)
		case .Output:
			return read_published(&self.meter_out)
		}
		return 0
	},
}

//
// clap.audio-ports — two stereo inputs (main + sidechain), one stereo output.
//
// The sidechain is an ordinary extra input port: CLAP has no dedicated sidechain flag, so
// it is identified by not carrying IS_MAIN. Hosts leave it disconnected unless the user
// routes something to it, and `process` falls back to the main input in that case.
//

SIDECHAIN_PORT :: 1

audio_ports_ext := ext.Plugin_Audio_Ports {
	count = proc "c" (plugin: ^clap.Plugin, is_input: bool) -> u32 {
		return is_input ? 2 : 1
	},

	get = proc "c" (
		plugin: ^clap.Plugin,
		index: u32,
		is_input: bool,
		info: ^ext.Audio_Port_Info,
	) -> bool {
		context = runtime.default_context()

		info.channel_count = 2
		info.port_type = ext.AUDIO_PORT_STEREO
		info.in_place_pair = clap.INVALID_ID

		if is_input && index == SIDECHAIN_PORT {
			info.id = SIDECHAIN_PORT
			copy(info.name[:], "Sidechain")
			info.flags = 0
			return true
		}

		if index != 0 {
			return false
		}
		info.id = 0
		copy(info.name[:], "Main")
		info.flags = u32(ext.Audio_Port_Flag.IS_MAIN)
		return true
	},
}

//
// clap.latency — the lookahead delay.
//
// Latched at activate and constant for the lifetime of that activation, as CLAP requires.
// A lookahead change while active is announced from on_main_thread, which then requests a
// restart so the host picks up the new value.
//

latency_ext := ext.Plugin_Latency {
	get = proc "c" (plugin: ^clap.Plugin) -> u32 {
		return from_plugin(plugin).latency_samples
	},
}

//
// clap.tail
//
// A compressor generates no signal of its own: when the input goes silent the output
// follows. What remains is whatever the lookahead delay is still holding, so the tail is
// exactly the delay length. Release time does not extend it — a gain envelope returning
// to unity has nothing to act on.
//

tail_ext := ext.Plugin_Tail {
	get = proc "c" (plugin: ^clap.Plugin) -> u32 {
		return from_plugin(plugin).latency_samples
	},
}
