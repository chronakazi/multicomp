package plugin

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"
import "proj:src/dsp"

// The parameter table is the single source of truth: id, name, module, range, flags and
// display formatting all live here. `clap.params`, state serialisation and (from Phase 6)
// the GUI all read from it, so they cannot drift apart.

Param_Id :: enum clap.Clap_Id {
	Bypass = 0,
	Input_Trim,
	Threshold,
	Ratio,
	Knee,
	Attack,
	Release,
	Auto_Release,
	Detector,
	Topology,
	Stereo_Link,
	Channel_Mode,
	Lookahead,
	Sidechain_Source,
	Sidechain_Highpass,
	Sidechain_Listen,
	Makeup,
	Auto_Makeup,
	Mix,
	Output_Trim,
}

// How a value is rendered and parsed. The DSP meaning of a parameter lives in dsp/;
// this is purely about presentation.
Param_Kind :: enum {
	Decibel,
	Ratio,
	Time_Ms,
	Frequency_Hz,
	Percent,
	Boolean,
	Choice,
}

Param :: struct {
	name:    string,
	module:  string, // CLAP module path, groups params in host generic UIs
	kind:    Param_Kind,
	min:     f64,
	max:     f64,
	default: f64,
	flags:   u32,
	choices: []string, // Choice only; index is the parameter value
}

// Ratio is stored in ratio units so a DAW automation lane reads the way an engineer
// expects. The top of the range means infinite ratio, i.e. limiting.
RATIO_MAX :: 20.0

// The bottom of the sidechain high-pass range means "off", so the default detector path is
// genuinely unfiltered rather than merely nearly so.
SIDECHAIN_HIGHPASS_MIN :: 20.0

FLAG_AUTOMATABLE :: u32(ext.Param_Info_Flag.AUTOMATABLE)
FLAG_MODULATABLE :: u32(ext.Param_Info_Flag.MODULATABLE)
FLAG_STEPPED :: u32(ext.Param_Info_Flag.STEPPED)
FLAG_ENUM :: u32(ext.Param_Info_Flag.IS_ENUM)
FLAG_BYPASS :: u32(ext.Param_Info_Flag.BYPASS)
FLAG_HIDDEN :: u32(ext.Param_Info_Flag.HIDDEN)

// Continuous parameters can be modulated; stepped ones only automated.
FLAGS_CONTINUOUS :: FLAG_AUTOMATABLE | FLAG_MODULATABLE
FLAGS_SWITCH :: FLAG_AUTOMATABLE | FLAG_STEPPED
FLAGS_CHOICE :: FLAG_AUTOMATABLE | FLAG_STEPPED | FLAG_ENUM

// Parameters that exist in the table but whose behaviour is not implemented yet.
// CLAP documents IS_HIDDEN as precisely this case: "the parameter should not be shown to
// the user, because it is currently not used". Without it a host's generic UI offers
// controls that silently do nothing, which reads as a bug.
//
// Drop NOT_IMPLEMENTED from a parameter in the same change that makes it work.
// Nothing carries it as of Phase 4 - every parameter in the table does something.
NOT_IMPLEMENTED :: FLAG_HIDDEN

ON_OFF := []string{"Off", "On"}

// Indexed by Param_Id, so lookup is O(1) and the table can never fall out of order.
PARAMS := [Param_Id]Param {
	.Bypass = {
		name = "Bypass",
		kind = .Boolean,
		min = 0,
		max = 1,
		default = 0,
		flags = FLAGS_SWITCH | FLAG_BYPASS,
		choices = ON_OFF,
	},
	.Input_Trim = {
		name = "Input Trim",
		kind = .Decibel,
		min = -24,
		max = 24,
		default = 0,
		flags = FLAGS_CONTINUOUS,
	},

	// Compression curve
	.Threshold = {
		name = "Threshold",
		module = "Compressor",
		kind = .Decibel,
		min = -60,
		max = 0,
		default = -18,
		flags = FLAGS_CONTINUOUS,
	},
	// Defaults to 1:1 so the plugin is bit-transparent the moment it is inserted. At 1:1
	// the gain computer returns its input unchanged at every level, so the applied gain is
	// exactly 1.0 regardless of threshold or knee. Threshold stays at a musically useful
	// -18 dB, so raising ratio is the single gesture that starts compression.
	.Ratio = {
		name = "Ratio",
		module = "Compressor",
		kind = .Ratio,
		min = 1,
		max = RATIO_MAX,
		default = 1,
		flags = FLAGS_CONTINUOUS,
	},
	.Knee = {
		name = "Knee",
		module = "Compressor",
		kind = .Decibel,
		min = 0,
		max = 24,
		default = 6,
		flags = FLAGS_CONTINUOUS,
	},

	// Envelope
	.Attack = {
		name = "Attack",
		module = "Envelope",
		kind = .Time_Ms,
		min = 0.1,
		max = 300,
		default = 10,
		flags = FLAGS_CONTINUOUS,
	},
	.Release = {
		name = "Release",
		module = "Envelope",
		kind = .Time_Ms,
		min = 5,
		max = 3000,
		default = 100,
		flags = FLAGS_CONTINUOUS,
	},
	.Auto_Release = {
		name = "Auto Release",
		module = "Envelope",
		kind = .Boolean,
		min = 0,
		max = 1,
		default = 0,
		flags = FLAGS_SWITCH,
		choices = ON_OFF,
	},

	// Detector
	.Detector = {
		name = "Detector",
		module = "Detector",
		kind = .Choice,
		min = 0,
		max = f64(len(dsp.Detector_Mode) - 1),
		default = f64(dsp.Detector_Mode.Peak),
		flags = FLAGS_CHOICE,
		choices = DETECTOR_CHOICES,
	},
	.Topology = {
		name = "Topology",
		module = "Detector",
		kind = .Choice,
		min = 0,
		max = f64(len(dsp.Topology_Mode) - 1),
		default = f64(dsp.Topology_Mode.Feed_Forward),
		flags = FLAGS_CHOICE,
		choices = TOPOLOGY_CHOICES,
	},
	.Stereo_Link = {
		name = "Stereo Link",
		module = "Detector",
		kind = .Percent,
		min = 0,
		max = 100,
		default = 100,
		flags = FLAGS_CONTINUOUS,
	},
	.Channel_Mode = {
		name = "Channel Mode",
		module = "Detector",
		kind = .Choice,
		min = 0,
		max = f64(len(Channel_Mode_Value) - 1),
		default = f64(Channel_Mode_Value.Stereo),
		flags = FLAGS_CHOICE,
		choices = CHANNEL_MODE_CHOICES,
	},
	// Deliberately neither automatable nor modulatable. Changing lookahead changes the
	// plugin's latency, and CLAP requires reported latency to stay constant while active,
	// so every change costs a deactivate/reactivate round trip. Automating that would
	// thrash the host. It is a setup control, not a performance control.
	.Lookahead = {
		name = "Lookahead",
		module = "Detector",
		kind = .Time_Ms,
		min = 0,
		max = MAX_LOOKAHEAD_MS,
		default = 0,
		flags = 0,
	},

	// Sidechain
	.Sidechain_Source = {
		name = "SC Source",
		module = "Sidechain",
		kind = .Choice,
		min = 0,
		max = f64(len(Sidechain_Source_Value) - 1),
		default = f64(Sidechain_Source_Value.Internal),
		flags = FLAGS_CHOICE,
		choices = SIDECHAIN_SOURCE_CHOICES,
	},
	.Sidechain_Highpass = {
		name = "SC High-Pass",
		module = "Sidechain",
		kind = .Frequency_Hz,
		min = SIDECHAIN_HIGHPASS_MIN,
		max = 500,
		default = SIDECHAIN_HIGHPASS_MIN,
		flags = FLAGS_CONTINUOUS,
	},
	.Sidechain_Listen = {
		name = "SC Listen",
		module = "Sidechain",
		kind = .Boolean,
		min = 0,
		max = 1,
		default = 0,
		flags = FLAGS_SWITCH,
		choices = ON_OFF,
	},

	// Output stage
	.Makeup = {
		name = "Makeup",
		module = "Output",
		kind = .Decibel,
		min = -12,
		max = 24,
		default = 0,
		flags = FLAGS_CONTINUOUS,
	},
	.Auto_Makeup = {
		name = "Auto Makeup",
		module = "Output",
		kind = .Boolean,
		min = 0,
		max = 1,
		default = 0,
		flags = FLAGS_SWITCH,
		choices = ON_OFF,
	},
	.Mix = {
		name = "Mix",
		module = "Output",
		kind = .Percent,
		min = 0,
		max = 100,
		default = 100,
		flags = FLAGS_CONTINUOUS,
	},
	.Output_Trim = {
		name = "Output Trim",
		module = "Output",
		kind = .Decibel,
		min = -24,
		max = 24,
		default = 0,
		flags = FLAGS_CONTINUOUS,
	},
}

// Enumerated parameter values. `Detector_Mode` and `Topology_Mode` are owned by the dsp
// package, since that is what switches on them - defining them twice would let the
// display strings drift away from the behaviour. These string tables are display only.

DETECTOR_CHOICES := []string{"Peak", "RMS", "Hybrid"}
TOPOLOGY_CHOICES := []string{"Feed-Forward", "Feedback"}

Channel_Mode_Value :: enum {
	Stereo,
	Mid_Side,
}
CHANNEL_MODE_CHOICES := []string{"Stereo", "Mid-Side"}

Sidechain_Source_Value :: enum {
	Internal,
	External,
}
SIDECHAIN_SOURCE_CHOICES := []string{"Internal", "External"}

//
// Lookup and value handling
//

is_valid_param :: proc "contextless" (id: clap.Clap_Id) -> bool {
	return id < len(PARAMS)
}

// Stepped parameters must land exactly on integers, or hosts and our own choice
// indexing disagree about what the value means.
clamp_param :: proc "contextless" (id: Param_Id, value: f64) -> f64 {
	param := PARAMS[id]
	result := clamp(value, param.min, param.max)
	if param.flags & FLAG_STEPPED != 0 {
		result = math.round(result)
	}
	return result
}

choice_index :: proc "contextless" (param: Param, value: f64) -> int {
	if len(param.choices) == 0 {
		return 0
	}
	return clamp(int(math.round(value)), 0, len(param.choices) - 1)
}

//
// Display
//

format_param :: proc(param: Param, value: f64, buffer: []u8) -> string {
	switch param.kind {
	case .Decibel:
		return fmt.bprintf(buffer, "%.2f dB", value)
	case .Ratio:
		if value >= RATIO_MAX {
			return fmt.bprintf(buffer, "%s:1", INFINITY_TEXT)
		}
		return fmt.bprintf(buffer, "%.1f:1", value)
	case .Time_Ms:
		return fmt.bprintf(buffer, "%.2f ms", value)
	case .Frequency_Hz:
		return fmt.bprintf(buffer, "%.0f Hz", value)
	case .Percent:
		return fmt.bprintf(buffer, "%.1f %%", value)
	case .Boolean, .Choice:
		return fmt.bprintf(buffer, "%s", param.choices[choice_index(param, value)])
	}
	return fmt.bprintf(buffer, "%.2f", value)
}

INFINITY_TEXT :: "∞" // ∞

parse_param :: proc(param: Param, text: string) -> (value: f64, ok: bool) {
	trimmed := strings.trim_space(text)
	if len(trimmed) == 0 {
		return 0, false
	}

	// Named values first: these never look like numbers.
	switch param.kind {
	case .Boolean, .Choice:
		for choice, index in param.choices {
			if strings.equal_fold(trimmed, choice) {
				return f64(index), true
			}
		}
		// Fall through to numeric parsing so a host can send a raw index.
	case .Ratio:
		if strings.has_prefix(trimmed, INFINITY_TEXT) ||
		   strings.equal_fold(trimmed, "inf") ||
		   strings.equal_fold(trimmed, "infinity") {
			return param.max, true
		}
	case .Decibel, .Time_Ms, .Frequency_Hz, .Percent:
	// Numeric only.
	}

	// Parse the numeric prefix so trailing units ("-12.50 dB", "4.0:1") are accepted.
	parsed, consumed, parse_ok := strconv.parse_f64_prefix(trimmed)
	if !parse_ok || consumed == 0 {
		return 0, false
	}
	return parsed, true
}

//
// clap.params
//

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

		id := Param_Id(param_index)
		param := PARAMS[id]

		param_info^ = {}
		param_info.id = u32(id)
		param_info.flags = param.flags
		copy(param_info.name[:], param.name)
		copy(param_info.module[:], param.module)
		param_info.min_value = param.min
		param_info.max_value = param.max
		param_info.default_value = param.default
		return true
	},

	get_value = proc "c" (plugin: ^clap.Plugin, param_id: clap.Clap_Id, out_value: ^f64) -> bool {
		if !is_valid_param(param_id) {
			return false
		}
		self := from_plugin(plugin)
		out_value^ = self.values[Param_Id(param_id)]
		return true
	},

	value_to_text = proc "c" (
		plugin: ^clap.Plugin,
		param_id: clap.Clap_Id,
		value: f64,
		out_buffer: [^]u8,
		out_buffer_capacity: u32,
	) -> bool {
		if !is_valid_param(param_id) || out_buffer_capacity == 0 {
			return false
		}
		context = runtime.default_context()

		param := PARAMS[Param_Id(param_id)]
		buffer := out_buffer[:out_buffer_capacity]
		text := format_param(param, value, buffer[:out_buffer_capacity - 1])
		buffer[len(text)] = 0
		return true
	},

	text_to_value = proc "c" (
		plugin: ^clap.Plugin,
		param_id: clap.Clap_Id,
		param_value_text: cstring,
		out_value: ^f64,
	) -> bool {
		if !is_valid_param(param_id) {
			return false
		}
		context = runtime.default_context()

		id := Param_Id(param_id)
		value, ok := parse_param(PARAMS[id], string(param_value_text))
		if !ok {
			return false
		}
		out_value^ = clamp_param(id, value)
		return true
	},

	// Applies parameter changes while the plugin is not processing. Same event handling
	// as `process`, minus the audio.
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
