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
// clap.state
//
// The format is deliberately trivial for Phase 0. Phase 1 replaces it with a versioned
// encoding — a magic number and a version field first, so old sessions keep loading as
// the parameter set grows.
//

state_ext := ext.Plugin_State {
	save = proc "c" (plugin: ^clap.Plugin, stream: ^clap.Ostream) -> bool {
		self := from_plugin(plugin)
		value := self.gain_db
		return write_full(stream, &value, size_of(f64))
	},

	load = proc "c" (plugin: ^clap.Plugin, stream: ^clap.Istream) -> bool {
		self := from_plugin(plugin)
		value: f64
		if !read_full(stream, &value, size_of(f64)) {
			return false
		}
		self.gain_db = value
		return true
	},
}

// Hosts may satisfy a read or write partially, so both directions have to loop.
// The validator exercises this with deliberately tiny chunk sizes.
write_full :: proc "contextless" (stream: ^clap.Ostream, data: rawptr, size: int) -> bool {
	bytes := ([^]u8)(data)
	written := 0
	for written < size {
		n := stream.write(stream, &bytes[written], u64(size - written))
		if n <= 0 {
			return false
		}
		written += int(n)
	}
	return true
}

read_full :: proc "contextless" (stream: ^clap.Istream, data: rawptr, size: int) -> bool {
	bytes := ([^]u8)(data)
	read := 0
	for read < size {
		n := stream.read(stream, &bytes[read], u64(size - read))
		if n <= 0 {
			return false // 0 is end of file, -1 is an error; both are failures here
		}
		read += int(n)
	}
	return true
}

//
// clap.latency — zero until Phase 3 introduces the lookahead delay.
//

latency_ext := ext.Plugin_Latency {
	get = proc "c" (plugin: ^clap.Plugin) -> u32 {
		return 0
	},
}
