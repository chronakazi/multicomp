package offline

// Minimal offline CLAP host: loads the built plugin, drives audio through it, and
// measures what comes out. Verifies behaviour clap-validator does not check - whether the
// compressor actually applies the gain reduction its own curve asks for.

import "core:dynlib"
import "core:fmt"
import "core:math"
import "core:os"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"

SR :: 48000.0
CHANNELS :: 2

// Parameters are looked up by name, so reordering Param_Id cannot silently invalidate
// these checks.

host := clap.Host {
	clap_version = clap.CLAP_VERSION,
	name = "offline",
	vendor = "scratch",
	url = "",
	version = "0.1.0",
	get_extension = proc "c" (host: ^clap.Host, id: cstring) -> rawptr {return nil},
	request_restart = proc "c" (host: ^clap.Host) {},
	request_process = proc "c" (host: ^clap.Host) {},
	request_callback = proc "c" (host: ^clap.Host) {},
}

//
// Event lists
//

Event_List :: struct {
	vtable: clap.Input_Events,
	items:  [dynamic]clap.Event_Param_Value,
}

event_list_init :: proc(list: ^Event_List) {
	list.vtable.ctx = list
	list.vtable.size = proc "c" (l: ^clap.Input_Events) -> u32 {
		return u32(len((^Event_List)(l.ctx).items))
	}
	list.vtable.get = proc "c" (l: ^clap.Input_Events, index: u32) -> ^clap.Event_Header {
		return &(^Event_List)(l.ctx).items[index].header
	}
}

event_list_push :: proc(list: ^Event_List, param_id: u32, value: f64, time: u32 = 0) {
	event := clap.Event_Param_Value {
		header = {
			size = size_of(clap.Event_Param_Value),
			time = time,
			space_id = clap.CORE_EVENT_SPACE_ID,
			type = u16(clap.Event_Type.PARAM_VALUE),
			flags = 0,
		},
		param_id = param_id,
		cookie = nil,
		note_id = -1,
		port_index = -1,
		channel = -1,
		key = -1,
		value = value,
	}
	append(&list.items, event)
}

sink := clap.Output_Events {
	ctx = nil,
	try_push = proc "c" (l: ^clap.Output_Events, e: ^clap.Event_Header) -> bool {return true},
}

//
// Audio buffers
//

Buffers :: struct {
	buffer:   clap.Audio_Buffer,
	channels: [CHANNELS][^]f32,
	data:     [CHANNELS][]f32,
}

buffers_make :: proc(frames: int) -> (b: ^Buffers) {
	b = new(Buffers)
	for i in 0 ..< CHANNELS {
		b.data[i] = make([]f32, frames)
		b.channels[i] = raw_data(b.data[i])
	}
	b.buffer = clap.Audio_Buffer {
		data32        = raw_data(b.channels[:]),
		data64        = nil,
		channel_count = CHANNELS,
		latency       = 0,
		constant_mask = 0,
	}
	return
}

//
// Plugin handle
//

Plugin :: struct {
	entry:   ^clap.Plugin_Entry,
	factory: ^clap.Plugin_Factory,
	plugin:  ^clap.Plugin,
	params:  ^ext.Plugin_Params,
	latency: ^ext.Plugin_Latency,
	tail:    ^ext.Plugin_Tail,
}

plugin_load :: proc(path: string) -> (p: Plugin, ok: bool) {
	lib, loaded := dynlib.load_library(path)
	if !loaded {
		fmt.eprintfln("dlopen failed: %s", dynlib.last_error())
		return {}, false
	}
	sym, found := dynlib.symbol_address(lib, "clap_entry")
	if !found {
		fmt.eprintfln("clap_entry not found")
		return {}, false
	}

	p.entry = (^clap.Plugin_Entry)(sym)
	p.entry.init(cstring(raw_data(path)))
	p.factory = (^clap.Plugin_Factory)(p.entry.get_factory(clap.PLUGIN_FACTORY_ID))
	desc := p.factory.get_plugin_descriptor(p.factory, 0)
	p.plugin = p.factory.create_plugin(p.factory, &host, desc.id)
	p.plugin.init(p.plugin)

	p.params = (^ext.Plugin_Params)(p.plugin.get_extension(p.plugin, ext.EXT_PARAMS))
	p.latency = (^ext.Plugin_Latency)(p.plugin.get_extension(p.plugin, ext.EXT_LATENCY))
	p.tail = (^ext.Plugin_Tail)(p.plugin.get_extension(p.plugin, ext.EXT_TAIL))
	return p, true
}

// Resolves a parameter id from its display name. Exits rather than silently testing the
// wrong parameter if the name is not found.
param_id :: proc(p: Plugin, name: string) -> u32 {
	count := p.params.count(p.plugin)
	for i in 0 ..< count {
		info: ext.Param_Info
		if !p.params.get_info(p.plugin, i, &info) {
			continue
		}
		if string(cstring(raw_data(info.name[:]))) == name {
			return info.id
		}
	}
	fmt.eprintfln("no such parameter: %q", name)
	os.exit(1)
}

Setting :: struct {
	name:  string,
	value: f64,
}

set_params :: proc(p: Plugin, settings: []Setting) {
	list: Event_List
	event_list_init(&list)
	defer delete(list.items)
	for setting in settings {
		event_list_push(&list, param_id(p, setting.name), setting.value)
	}
	p.params.flush(p.plugin, &list.vtable, &sink)
}

// Runs `seconds` of a sine through the plugin and returns the peak output amplitude over
// the final quarter, by which point the envelope has settled.
run_sine :: proc(p: Plugin, amplitude, frequency, seconds: f64, block: int = 512) -> f64 {
	input := buffers_make(block)
	output := buffers_make(block)

	empty: Event_List
	event_list_init(&empty)

	total := int(SR * seconds)
	phase := 0.0
	step := 2 * math.PI * frequency / SR
	peak := 0.0
	measure_from := total * 3 / 4
	produced := 0

	p.plugin.start_processing(p.plugin)
	for produced < total {
		frames := min(block, total - produced)
		for i in 0 ..< frames {
			value := f32(amplitude * math.sin(phase))
			phase += step
			for c in 0 ..< CHANNELS {
				input.data[c][i] = value
			}
		}

		process := clap.Process {
			steady_time         = i64(produced),
			frames_count        = u32(frames),
			transport           = nil,
			audio_inputs        = &input.buffer,
			audio_outputs       = &output.buffer,
			audio_inputs_count  = 1,
			audio_outputs_count = 1,
			in_events           = &empty.vtable,
			out_events          = &sink,
		}
		p.plugin.process(p.plugin, &process)

		for i in 0 ..< frames {
			if produced + i >= measure_from {
				peak = max(peak, f64(abs(output.data[0][i])))
			}
		}
		produced += frames
	}
	p.plugin.stop_processing(p.plugin)
	return peak
}

// Sends a single full-scale impulse and returns the sample index where it reappears.
measure_impulse_delay :: proc(p: Plugin, block: int = 512) -> int {
	input := buffers_make(block)
	output := buffers_make(block)
	empty: Event_List
	event_list_init(&empty)

	p.plugin.start_processing(p.plugin)
	defer p.plugin.stop_processing(p.plugin)

	found := -1
	produced := 0
	for round in 0 ..< 8 {
		for c in 0 ..< CHANNELS {
			for i in 0 ..< block {
				input.data[c][i] = 0
			}
		}
		if round == 0 {
			for c in 0 ..< CHANNELS {
				input.data[c][0] = 1
			}
		}

		process := clap.Process {
			steady_time         = i64(produced),
			frames_count        = u32(block),
			transport           = nil,
			audio_inputs        = &input.buffer,
			audio_outputs       = &output.buffer,
			audio_inputs_count  = 1,
			audio_outputs_count = 1,
			in_events           = &empty.vtable,
			out_events          = &sink,
		}
		p.plugin.process(p.plugin, &process)

		if found < 0 {
			for i in 0 ..< block {
				if abs(output.data[0][i]) > 0.001 {
					found = produced + i
					break
				}
			}
		}
		produced += block
	}
	return found
}

failures := 0

check :: proc(name: string, actual, expected, tolerance: f64, unit := "dB") {
	delta := abs(actual - expected)
	status := delta <= tolerance ? "ok  " : "FAIL"
	if delta > tolerance {
		failures += 1
	}
	fmt.printfln(
		"  %s %-42s got %8.3f %s, expected %8.3f (+/- %.3f)",
		status,
		name,
		actual,
		unit,
		expected,
		tolerance,
	)
}

db :: proc(linear: f64) -> f64 {
	return linear <= 0 ? -200 : 20 * math.log10(linear)
}

// Amplitude for a given dBFS level.
from_db :: proc(level: f64) -> f64 {
	return math.pow(f64(10), level * 0.05)
}

main :: proc() {
	path := os.args[1]
	p, ok := plugin_load(path)
	if !ok {
		os.exit(1)
	}

	// Inserting the plugin and touching nothing must not change the signal at all. This is
	// a regression guard: an earlier build defaulted to 4:1 at -18 dB and pulled 9 dB off
	// typical program material the moment it was inserted.
	fmt.println("factory defaults are transparent")
	p.plugin.activate(p.plugin, SR, 1, 512)
	for level in ([?]f64{-30, -18, -12, -6, -3}) {
		out := db(run_sine(p, from_db(level), 1000, 0.5))
		check(fmt.tprintf("untouched at %.0f dBFS in", level), out, level, 0.01)
	}

	// Every parameter flagged hidden is one whose behaviour is not implemented yet. A
	// visible control that does nothing reads as a bug to whoever is using it.
	fmt.println()
	fmt.println("parameter visibility")
	hidden, visible := 0, 0
	for i in 0 ..< p.params.count(p.plugin) {
		info: ext.Param_Info
		if !p.params.get_info(p.plugin, i, &info) {
			continue
		}
		if info.flags & u32(ext.Param_Info_Flag.HIDDEN) != 0 {
			hidden += 1
		} else {
			visible += 1
		}
	}
	fmt.printfln("  %d visible, %d hidden pending implementation", visible, hidden)

	fmt.println()
	fmt.println("compression curve (threshold -20, ratio 4, hard knee)")
	set_params(
		p,
		[]Setting {
			{"Threshold", -20},
			{"Ratio", 4},
			{"Knee", 0},
			{"Attack", 1},
			{"Release", 50},
			{"Detector", 0},
			{"Makeup", 0},
			{"Lookahead", 0},
			{"Bypass", 0},
		},
	)

	// 12 dB over threshold at 4:1 -> 3 dB over, so -17 dBFS out.
	out := db(run_sine(p, from_db(-8.0), 1000, 1.0))
	check("-8 dBFS in  (12 dB over, 4:1)", out, -17, 0.6)

	// 20 dB over -> 5 dB over.
	out = db(run_sine(p, from_db(0.0), 1000, 1.0))
	check("0 dBFS in   (20 dB over, 4:1)", out, -15, 0.6)

	// Below threshold: untouched.
	out = db(run_sine(p, from_db(-40.0), 1000, 0.5))
	check("-40 dBFS in (below threshold)", out, -40, 0.2)

	fmt.println()
	fmt.println("ratio")
	set_params(p, []Setting{{"Ratio", 2}})
	out = db(run_sine(p, from_db(-8.0), 1000, 1.0))
	check("-8 dBFS in at 2:1", out, -14, 0.6)

	set_params(p, []Setting{{"Ratio", 20}}) // top of range = infinite
	out = db(run_sine(p, from_db(-8.0), 1000, 1.0))
	check("-8 dBFS in at inf:1 (limiting)", out, -20, 0.6)

	fmt.println()
	fmt.println("gain staging")
	set_params(p, []Setting{{"Ratio", 4}, {"Makeup", 6}})
	out = db(run_sine(p, from_db(-8.0), 1000, 1.0))
	check("makeup +6 dB", out, -11, 0.6)

	set_params(p, []Setting{{"Makeup", 0}, {"Output Trim", -6}})
	out = db(run_sine(p, from_db(-8.0), 1000, 1.0))
	check("output trim -6 dB", out, -23, 0.6)

	set_params(p, []Setting{{"Output Trim", 0}, {"Input Trim", 6}})
	// +6 dB in makes it 18 dB over; at 4:1 that is 4.5 dB over, plus the 6 dB of trim
	// on the signal path -> -20 + 4.5 = -15.5 dBFS.
	out = db(run_sine(p, from_db(-8.0), 1000, 1.0))
	check("input trim +6 dB", out, -15.5, 0.6)

	fmt.println()
	fmt.println("bypass")
	set_params(p, []Setting{{"Input Trim", 0}, {"Bypass", 1}})
	out = db(run_sine(p, from_db(-8.0), 1000, 0.5))
	check("bypassed signal is untouched", out, -8, 0.05)
	set_params(p, []Setting{{"Bypass", 0}})

	fmt.println()
	fmt.println("lookahead and latency")
	check("latency at 0 ms lookahead", f64(p.latency.get(p.plugin)), 0, 0, "smp")
	check("impulse delay at 0 ms", f64(measure_impulse_delay(p)), 0, 0, "smp")

	// Latency is latched at activate, so lookahead needs a reactivation to take effect.
	p.plugin.deactivate(p.plugin)
	set_params(p, []Setting{{"Lookahead", 5}})
	p.plugin.activate(p.plugin, SR, 1, 512)

	expected_latency := math.round(f64(5.0 / 1000 * SR))
	check("latency at 5 ms lookahead", f64(p.latency.get(p.plugin)), expected_latency, 0, "smp")
	check("tail matches latency", f64(p.tail.get(p.plugin)), expected_latency, 0, "smp")
	check("impulse delay at 5 ms", f64(measure_impulse_delay(p)), expected_latency, 0, "smp")

	p.plugin.deactivate(p.plugin)
	p.plugin.destroy(p.plugin)
	p.entry.deinit()

	fmt.println()
	if failures == 0 {
		fmt.println("all offline checks passed")
	} else {
		fmt.printfln("%d offline checks FAILED", failures)
		os.exit(1)
	}
}
