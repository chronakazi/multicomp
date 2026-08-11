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
	case ext.EXT_AUDIO_PORTS_CONFIG:
		return &audio_ports_config_ext
	case EXT_METERS:
		return &meters_ext
	case EXT_MIRROR:
		return &mirror_ext
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
// Mirror readback. Also not a CLAP extension. The GUI never reads the audio thread's
// parameter array; it reads an atomic mirror of it, so "what the panel shows" and "what
// params.get_value reports" are two different questions and can disagree. This exposes
// the first one, which is otherwise only reachable by opening a window.
//

EXT_MIRROR :: "com.foesoft.multicomp.mirror"

Plugin_Mirror :: struct {
	get: proc "c" (plugin: ^clap.Plugin, param_id: clap.Clap_Id) -> f64,
}

mirror_ext := Plugin_Mirror {
	get = proc "c" (plugin: ^clap.Plugin, param_id: clap.Clap_Id) -> f64 {
		if !is_valid_param(param_id) {
			return 0
		}
		return read_published(&from_plugin(plugin).mirror[Param_Id(param_id)])
	},
}

//
// clap.audio-ports — two inputs (main + sidechain), one output. Main in/out are stereo
// by default and mono under the mono port configuration; the sidechain is always stereo.
//
// The sidechain is an ordinary extra input port: CLAP has no dedicated sidechain flag, so
// it is identified by not carrying IS_MAIN. Hosts leave it disconnected unless the user
// routes something to it, and `process` falls back to the main input in that case.
//

SIDECHAIN_PORT :: 1

// The selectable port layouts, from clap.audio-ports-config. "Stereo" is the default;
// "Mono" narrows the main ports to one channel so the plugin drops cleanly onto a mono
// track. The sidechain input stays stereo in both.
Port_Config :: enum u32 {
	Stereo,
	Mono,
}

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
		self := from_plugin(plugin)

		info.in_place_pair = clap.INVALID_ID

		// The sidechain is always stereo, whatever the main configuration.
		if is_input && index == SIDECHAIN_PORT {
			info.id = SIDECHAIN_PORT
			copy(info.name[:], "Sidechain")
			info.flags = 0
			info.channel_count = 2
			info.port_type = ext.AUDIO_PORT_STEREO
			return true
		}

		if index != 0 {
			return false
		}
		mono := self.port_config == .Mono
		info.id = 0
		copy(info.name[:], "Main")
		info.flags = u32(ext.Audio_Port_Flag.IS_MAIN)
		info.channel_count = mono ? 1 : 2
		info.port_type = mono ? ext.AUDIO_PORT_MONO : ext.AUDIO_PORT_STEREO
		return true
	},
}

//
// clap.audio-ports-config — the preset port layouts above, selectable while deactivated.
//

audio_ports_config_ext := ext.Plugin_Audio_Ports_Config {
	count = proc "c" (plugin: ^clap.Plugin) -> u32 {
		return len(Port_Config)
	},

	get = proc "c" (plugin: ^clap.Plugin, index: u32, config: ^ext.Audio_Ports_Config) -> bool {
		if index >= u32(len(Port_Config)) {
			return false
		}
		context = runtime.default_context()

		mono := Port_Config(index) == .Mono
		config^ = {}
		config.id = clap.Clap_Id(index)
		copy(config.name[:], mono ? "Mono" : "Stereo")
		config.input_port_count = 2 // main + sidechain
		config.output_port_count = 1
		config.has_main_input = true
		config.main_input_channel_count = mono ? 1 : 2
		config.main_input_port_type = mono ? ext.AUDIO_PORT_MONO : ext.AUDIO_PORT_STEREO
		config.has_main_output = true
		config.main_output_channel_count = mono ? 1 : 2
		config.main_output_port_type = mono ? ext.AUDIO_PORT_MONO : ext.AUDIO_PORT_STEREO
		return true
	},

	select = proc "c" (plugin: ^clap.Plugin, config_id: clap.Clap_Id) -> bool {
		// [main-thread & plugin-deactivated] - the port layout cannot change mid-stream.
		self := from_plugin(plugin)
		if self.activated || config_id >= clap.Clap_Id(len(Port_Config)) {
			return false
		}
		self.port_config = Port_Config(config_id)
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
