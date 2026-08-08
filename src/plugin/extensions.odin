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
	}
	return nil
}

//
// clap.audio-ports — one stereo in, one stereo out. Phase 4 adds the sidechain input.
//

audio_ports_ext := ext.Plugin_Audio_Ports {
	count = proc "c" (plugin: ^clap.Plugin, is_input: bool) -> u32 {
		return 1
	},

	get = proc "c" (
		plugin: ^clap.Plugin,
		index: u32,
		is_input: bool,
		info: ^ext.Audio_Port_Info,
	) -> bool {
		if index != 0 {
			return false
		}
		context = runtime.default_context()

		info.id = 0
		copy(info.name[:], "Main")
		info.flags = u32(ext.Audio_Port_Flag.IS_MAIN)
		info.channel_count = 2
		info.port_type = ext.AUDIO_PORT_STEREO
		info.in_place_pair = clap.INVALID_ID
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
