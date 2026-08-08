package plugin

import "base:runtime"
import "core:fmt"
import "core:strconv"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"

// Phase 0 carries a single placeholder parameter. Phase 1 turns `PARAMS` into the full
// compressor table described in PLAN.md — id, name, range, flags and formatters in one
// place, so `clap.params` and the GUI can never drift apart.

Param_Id :: enum clap.Clap_Id {
	Gain = 0,
}

Param :: struct {
	id:      Param_Id,
	name:    string,
	unit:    string,
	min:     f64,
	max:     f64,
	default: f64,
	flags:   u32,
}

PARAMS := [?]Param {
	{
		id = .Gain,
		name = "Gain",
		unit = "dB",
		min = -60,
		max = 12,
		default = 0,
		flags = u32(ext.Param_Info_Flag.AUTOMATABLE) | u32(ext.Param_Info_Flag.MODULATABLE),
	},
}

find_param :: proc "contextless" (id: clap.Clap_Id) -> (^Param, bool) {
	for &param in PARAMS {
		if u32(param.id) == id {
			return &param, true
		}
	}
	return nil, false
}

params_ext := ext.Plugin_Params {
	count = proc "c" (plugin: ^clap.Plugin) -> u32 {
		return len(PARAMS)
	},

	get_info = proc "c" (
		plugin: ^clap.Plugin,
		param_index: u32,
		param_info: ^ext.Param_Info,
	) -> bool {
		if param_index >= len(PARAMS) {
			return false
		}
		context = runtime.default_context()

		param := PARAMS[param_index]
		param_info^ = {}
		param_info.id = u32(param.id)
		param_info.flags = param.flags
		copy(param_info.name[:], param.name)
		param_info.min_value = param.min
		param_info.max_value = param.max
		param_info.default_value = param.default
		return true
	},

	get_value = proc "c" (plugin: ^clap.Plugin, param_id: clap.Clap_Id, out_value: ^f64) -> bool {
		self := from_plugin(plugin)
		switch Param_Id(param_id) {
		case .Gain:
			out_value^ = self.gain_db
			return true
		}
		return false
	},

	value_to_text = proc "c" (
		plugin: ^clap.Plugin,
		param_id: clap.Clap_Id,
		value: f64,
		out_buffer: [^]u8,
		out_buffer_capacity: u32,
	) -> bool {
		param, found := find_param(param_id)
		if !found || out_buffer_capacity == 0 {
			return false
		}
		context = runtime.default_context()

		buffer := out_buffer[:out_buffer_capacity]
		text := fmt.bprintf(buffer[:out_buffer_capacity - 1], "%.2f %s", value, param.unit)
		buffer[len(text)] = 0
		return true
	},

	text_to_value = proc "c" (
		plugin: ^clap.Plugin,
		param_id: clap.Clap_Id,
		param_value_text: cstring,
		out_value: ^f64,
	) -> bool {
		if _, found := find_param(param_id); !found {
			return false
		}
		context = runtime.default_context()

		value, ok := strconv.parse_f64(string(param_value_text))
		if !ok {
			return false
		}
		out_value^ = value
		return true
	},

	// Called when the host wants parameter changes applied while the plugin is not
	// processing. Same event handling as `process`, minus the audio.
	flush = proc "c" (
		plugin: ^clap.Plugin,
		in_events: ^clap.Input_Events,
		out_events: ^clap.Output_Events,
	) {
		self := from_plugin(plugin)
		count := in_events.size(in_events)
		for i in 0 ..< count {
			handle_event(self, in_events.get(in_events, i))
		}
	},
}
