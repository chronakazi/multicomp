package offline

// Minimal offline CLAP host: loads the built plugin, drives audio through it, and
// measures what comes out. Verifies behaviour clap-validator does not check - whether the
// compressor actually applies the gain reduction its own curve asks for.

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"

SR :: 48000.0
CHANNELS :: 2

// Parameters are looked up by name, so reordering Param_Id cannot silently invalidate
// these checks.

// Set when the plugin announces a latency change through clap.host latency.changed().
// The state-load check below depends on it.
latency_changed_count := 0

host_latency_ext := ext.Host_Latency {
	changed = proc "c" (host: ^clap.Host) {
		latency_changed_count += 1
	},
}

host := clap.Host {
	clap_version = clap.CLAP_VERSION,
	name = "offline",
	vendor = "scratch",
	url = "",
	version = "0.1.0",
	get_extension = proc "c" (host: ^clap.Host, id: cstring) -> rawptr {
		if string(id) == ext.EXT_LATENCY {
			return &host_latency_ext
		}
		return nil
	},
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
// State streams
//
// In-memory clap.Istream/Ostream, so the state round trip can be exercised without
// touching the filesystem.
//

// Copies a stream into a buffer in deliberately small chunks: hosts are allowed to
// satisfy a write partially, and the plugin is required to loop.
save_state :: proc(p: Plugin) -> (data: [dynamic]u8, ok: bool) {
	ostream := clap.Ostream {
		ctx = &data,
		write = proc "c" (s: ^clap.Ostream, buffer: rawptr, size: u64) -> i64 {
			// Called back on our own thread, so an Odin context is safe to install.
			context = runtime.default_context()
			target := cast(^[dynamic]u8)s.ctx
			bytes := ([^]u8)(buffer)
			n := min(int(size), 7) // partial on purpose
			for i in 0 ..< n {
				append(target, bytes[i])
			}
			return i64(n)
		},
	}
	if !p.state.save(p.plugin, &ostream) {
		return nil, false
	}
	return data, true
}

load_state :: proc(p: Plugin, data: []u8) -> bool {
	Source :: struct {
		data:   []u8,
		cursor: int,
	}
	source := Source{data = data}
	istream := clap.Istream {
		ctx = &source,
		read = proc "c" (s: ^clap.Istream, buffer: rawptr, size: u64) -> i64 {
			source := (^Source)(s.ctx)
			remaining := len(source.data) - source.cursor
			if remaining <= 0 {
				return 0
			}
			n := min(int(size), remaining, 5) // partial on purpose
			copy(([^]u8)(buffer)[:n], source.data[source.cursor:source.cursor + n])
			source.cursor += n
			return i64(n)
		},
	}
	return p.state.load(p.plugin, &istream)
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
	state:   ^ext.Plugin_State,
	ports:   ^ext.Plugin_Audio_Ports,
	configs: ^ext.Plugin_Audio_Ports_Config,
	meters:  ^Meter_Readback,
	mirror:  ^Mirror_Readback,
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
	path_c := strings.clone_to_cstring(path)
	defer delete(path_c)
	p.entry.init(path_c)
	p.factory = (^clap.Plugin_Factory)(p.entry.get_factory(clap.PLUGIN_FACTORY_ID))
	desc := p.factory.get_plugin_descriptor(p.factory, 0)
	p.plugin = p.factory.create_plugin(p.factory, &host, desc.id)
	p.plugin.init(p.plugin)

	p.params = (^ext.Plugin_Params)(p.plugin.get_extension(p.plugin, ext.EXT_PARAMS))
	p.latency = (^ext.Plugin_Latency)(p.plugin.get_extension(p.plugin, ext.EXT_LATENCY))
	p.tail = (^ext.Plugin_Tail)(p.plugin.get_extension(p.plugin, ext.EXT_TAIL))
	p.state = (^ext.Plugin_State)(p.plugin.get_extension(p.plugin, ext.EXT_STATE))
	p.ports = (^ext.Plugin_Audio_Ports)(p.plugin.get_extension(p.plugin, ext.EXT_AUDIO_PORTS))
	p.configs = (^ext.Plugin_Audio_Ports_Config)(
		p.plugin.get_extension(p.plugin, ext.EXT_AUDIO_PORTS_CONFIG),
	)
	p.meters = (^Meter_Readback)(p.plugin.get_extension(p.plugin, METER_READBACK_ID))
	p.mirror = (^Mirror_Readback)(p.plugin.get_extension(p.plugin, MIRROR_READBACK_ID))
	return p, true
}

// The plugin's meter readback interface: how the atomics the GUI displays are checked
// from here. Keeping it a named interface means the tool needs no knowledge of the
// plugin's struct layout, which is free to change.
METER_READBACK_ID :: "com.foesoft.multicomp.meters"

Meter_Kind :: enum i32 {
	Input           = 0,
	Gain_Reduction  = 1,
	Output          = 2,
}

Meter_Readback :: struct {
	get: proc "c" (plugin: ^clap.Plugin, kind: i32) -> f64,
}

measure_meter :: proc(p: Plugin, kind: Meter_Kind) -> f64 {
	if p.meters == nil || p.meters.get == nil {
		fmt.eprintln("plugin does not expose the meter readback interface")
		os.exit(1)
	}
	return p.meters.get(p.plugin, i32(kind))
}

// The plugin's parameter mirror: the atomic copy the GUI reads. Deliberately a separate
// question from params.get_value, which reports the audio thread's own array - the two
// can disagree, and when they do the panel is what the user sees.
MIRROR_READBACK_ID :: "com.foesoft.multicomp.mirror"

Mirror_Readback :: struct {
	get: proc "c" (plugin: ^clap.Plugin, param_id: u32) -> f64,
}

read_mirror :: proc(p: Plugin, param: u32) -> f64 {
	if p.mirror == nil || p.mirror.get == nil {
		fmt.eprintln("plugin does not expose the mirror readback interface")
		os.exit(1)
	}
	return p.mirror.get(p.plugin, param)
}

// Pushes one parameter event through a block whose sample loop cannot carry it: either a
// zero-length block, or an event stamped past the end. Both are host edge cases, and both
// used to be dropped on the floor with no way for the host to notice.
run_stray_event :: proc(p: Plugin, param: u32, value: f64, frames: u32, time: u32) {
	main := buffers_make(512)
	side := buffers_make(512)
	output := buffers_make(512)
	inputs := [2]clap.Audio_Buffer{main.buffer, side.buffer}

	list: Event_List
	event_list_init(&list)
	defer delete(list.items)
	event_list_push(&list, param, value, time)

	p.plugin.start_processing(p.plugin)
	block := clap.Process {
		steady_time         = 0,
		frames_count        = frames,
		transport           = nil,
		audio_inputs        = raw_data(inputs[:]),
		audio_outputs       = &output.buffer,
		audio_inputs_count  = 2,
		audio_outputs_count = 1,
		in_events           = &list.vtable,
		out_events          = &sink,
	}
	p.plugin.process(p.plugin, &block)
	p.plugin.stop_processing(p.plugin)
}

// A deliberately sloppy host: reports events it then refuses to hand over. Both process()
// and flush() have to treat a nil header as a hole to skip rather than a pointer.
holey_events :: proc() -> clap.Input_Events {
	return clap.Input_Events {
		ctx = nil,
		size = proc "c" (l: ^clap.Input_Events) -> u32 {return 4},
		get = proc "c" (l: ^clap.Input_Events, index: u32) -> ^clap.Event_Header {return nil},
	}
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

Run :: struct {
	amplitude:    f64, // main input, left channel
	frequency:    f64,
	seconds:      f64,
	right_scale:  f64, // 1 = same as left; used to test stereo link
	sc_amplitude: f64, // sidechain port; 0 leaves it silent
	sc_frequency: f64,
	block:        int,
}

DEFAULT_RUN :: Run {
	amplitude    = 1,
	frequency    = 1000,
	seconds      = 1,
	right_scale  = 1,
	sc_amplitude = 0,
	sc_frequency = 1000,
	block        = 512,
}

// Runs a signal through the plugin and returns the peak output of each channel over the
// final quarter, by which point the envelope has settled. Always presents two input ports
// so the sidechain path can be exercised.
run_stereo :: proc(p: Plugin, opts: Run) -> (left, right: f64) {
	block := opts.block
	main := buffers_make(block)
	side := buffers_make(block)
	output := buffers_make(block)

	inputs := [2]clap.Audio_Buffer{main.buffer, side.buffer}

	empty: Event_List
	event_list_init(&empty)

	total := int(SR * opts.seconds)
	phase, sc_phase := 0.0, 0.0
	step := 2 * math.PI * opts.frequency / SR
	sc_step := 2 * math.PI * opts.sc_frequency / SR
	measure_from := total * 3 / 4
	produced := 0

	p.plugin.start_processing(p.plugin)
	for produced < total {
		frames := min(block, total - produced)
		for i in 0 ..< frames {
			value := opts.amplitude * math.sin(phase)
			phase += step
			main.data[0][i] = f32(value)
			main.data[1][i] = f32(value * opts.right_scale)

			sc := opts.sc_amplitude * math.sin(sc_phase)
			sc_phase += sc_step
			side.data[0][i] = f32(sc)
			side.data[1][i] = f32(sc)
		}

		process := clap.Process {
			steady_time         = i64(produced),
			frames_count        = u32(frames),
			transport           = nil,
			audio_inputs        = raw_data(inputs[:]),
			audio_outputs       = &output.buffer,
			audio_inputs_count  = 2,
			audio_outputs_count = 1,
			in_events           = &empty.vtable,
			out_events          = &sink,
		}
		p.plugin.process(p.plugin, &process)

		for i in 0 ..< frames {
			if produced + i >= measure_from {
				left = max(left, f64(abs(output.data[0][i])))
				right = max(right, f64(abs(output.data[1][i])))
			}
		}
		produced += frames
	}
	p.plugin.stop_processing(p.plugin)
	return
}

run_sine :: proc(p: Plugin, amplitude, frequency, seconds: f64, block: int = 512) -> f64 {
	opts := DEFAULT_RUN
	opts.amplitude = amplitude
	opts.frequency = frequency
	opts.seconds = seconds
	opts.block = block
	left, _ := run_stereo(p, opts)
	return left
}

// Sends a single full-scale impulse and returns the sample index where it reappears.
measure_impulse_delay :: proc(p: Plugin, block: int = 512) -> int {
	input := buffers_make(block)
	side := buffers_make(block)
	output := buffers_make(block)
	inputs := [2]clap.Audio_Buffer{input.buffer, side.buffer}
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
			audio_inputs        = raw_data(inputs[:]),
			audio_outputs       = &output.buffer,
			audio_inputs_count  = 2,
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

// Ways a host can hand us a broken input port.
Degradation :: enum {
	No_Inputs, // audio_inputs_count = 0
	Nil_Input, // port present, data32 nil
	Zero_Channels, // port present, channel_count 0
}

// Drives a block of loud audio through with the input port missing or broken, and
// returns the peak output. Anything but silence - or a crash - is a failure.
run_degraded :: proc(p: Plugin, mode: Degradation, block: int = 512) -> f64 {
	input := buffers_make(block)
	output := buffers_make(block)
	for c in 0 ..< CHANNELS {
		for i in 0 ..< block {
			input.data[c][i] = 1 // loud, so a stale read is unmistakable
			output.data[c][i] = 0.5 // pre-filled, so "didn't write" is unmistakable
		}
	}
	broken := input.buffer
	switch mode {
	case .No_Inputs:
	// handled below, at the process struct
	case .Nil_Input:
		broken.data32 = nil
	case .Zero_Channels:
		broken.channel_count = 0
	}

	empty: Event_List
	event_list_init(&empty)
	defer delete(empty.items)

	process := clap.Process {
		steady_time         = 0,
		frames_count        = u32(block),
		transport           = nil,
		audio_inputs        = &broken,
		audio_outputs       = &output.buffer,
		audio_inputs_count  = mode == .No_Inputs ? 0 : 1,
		audio_outputs_count = 1,
		in_events           = &empty.vtable,
		out_events          = &sink,
	}

	p.plugin.start_processing(p.plugin)
	p.plugin.process(p.plugin, &process)
	p.plugin.stop_processing(p.plugin)

	peak := 0.0
	for c in 0 ..< CHANNELS {
		for i in 0 ..< block {
			peak = max(peak, f64(abs(output.data[c][i])))
		}
	}
	return db(peak)
}

// Runs a mono signal through a one-channel main in/out pair - the layout the mono port
// configuration declares. The sidechain port stays connected (stereo, silent), exactly
// as the configuration describes it.
run_mono :: proc(p: Plugin, amplitude, frequency, seconds: f64, block: int = 512) -> f64 {
	in_data := make([]f32, block)
	defer delete(in_data)
	out_data := make([]f32, block)
	defer delete(out_data)
	sc_data := make([]f32, 2 * block)
	defer delete(sc_data)

	in_ch := [1][^]f32{raw_data(in_data)}
	out_ch := [1][^]f32{raw_data(out_data)}
	sc_ch := [2][^]f32{raw_data(sc_data), raw_data(sc_data[block:])}

	inputs := [2]clap.Audio_Buffer {
		{data32 = raw_data(in_ch[:]), channel_count = 1},
		{data32 = raw_data(sc_ch[:]), channel_count = 2},
	}
	output := clap.Audio_Buffer {
		data32        = raw_data(out_ch[:]),
		channel_count = 1,
	}

	empty: Event_List
	event_list_init(&empty)
	defer delete(empty.items)

	total := int(SR * seconds)
	step := 2 * math.PI * frequency / SR
	phase := 0.0
	measure_from := total * 3 / 4
	produced := 0
	peak := 0.0

	p.plugin.start_processing(p.plugin)
	for produced < total {
		frames := min(block, total - produced)
		for i in 0 ..< frames {
			in_data[i] = f32(amplitude * math.sin(phase))
			phase += step
		}

		process := clap.Process {
			steady_time         = i64(produced),
			frames_count        = u32(frames),
			transport           = nil,
			audio_inputs        = raw_data(inputs[:]),
			audio_outputs       = &output,
			audio_inputs_count  = 2,
			audio_outputs_count = 1,
			in_events           = &empty.vtable,
			out_events          = &sink,
		}
		p.plugin.process(p.plugin, &process)

		for i in 0 ..< frames {
			if produced + i >= measure_from {
				peak = max(peak, f64(abs(out_data[i])))
			}
		}
		produced += frames
	}
	p.plugin.stop_processing(p.plugin)
	return peak
}

// Toggling bypass must crossfade, not switch. A hard switch between two different gain
// levels is a waveform discontinuity - a click - which shows up as a sample-to-sample
// jump far larger than anything the signal itself can produce. Returns the largest such
// jump over the run.
measure_bypass_transition :: proc(p: Plugin, block: int = 512) -> f64 {
	main := buffers_make(block)
	side := buffers_make(block)
	output := buffers_make(block)
	inputs := [2]clap.Audio_Buffer{main.buffer, side.buffer}

	empty: Event_List
	event_list_init(&empty)
	defer delete(empty.items)
	toggle: Event_List
	event_list_init(&toggle)
	event_list_push(&toggle, param_id(p, "Bypass"), 1)
	defer delete(toggle.items)

	total := int(SR * 0.5)
	step := 2 * math.PI * 1000 / SR
	phase := 0.0
	produced := 0
	previous := 0.0
	jump := 0.0

	p.plugin.start_processing(p.plugin)
	for produced < total {
		frames := min(block, total - produced)
		for i in 0 ..< frames {
			value := from_db(-8) * math.sin(phase)
			phase += step
			main.data[0][i] = f32(value)
			main.data[1][i] = f32(value)
			side.data[0][i] = 0
			side.data[1][i] = 0
		}

		process := clap.Process {
			steady_time         = i64(produced),
			frames_count        = u32(frames),
			transport           = nil,
			audio_inputs        = raw_data(inputs[:]),
			audio_outputs       = &output.buffer,
			audio_inputs_count  = 2,
			audio_outputs_count = 1,
			in_events           = produced == total / 2 ? &toggle.vtable : &empty.vtable,
			out_events          = &sink,
		}
		p.plugin.process(p.plugin, &process)

		for i in 0 ..< frames {
			current := f64(output.data[0][i])
			if produced + i > 0 {
				jump = max(jump, abs(current - previous))
			}
			previous = current
		}
		produced += frames
	}
	p.plugin.stop_processing(p.plugin)
	return jump
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
	p.plugin.activate(p.plugin, SR, 1, 512)

	// Read before any audio has run: activation must leave the meters at silence, not
	// at the 0 dBFS that zero-initialised atomics would decode as.
	fmt.println("meters")
	check("input meter starts at silence, not 0 dBFS", measure_meter(p, .Input), -120, 0.5)
	check("output meter starts at silence", measure_meter(p, .Output), -120, 0.5)
	check("gain reduction meter starts at zero", measure_meter(p, .Gain_Reduction), 0, 0.001)

	fmt.println()
	fmt.println("factory defaults are transparent")
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
	fmt.println("bypass crossfade")
	// A hard switch between two different gains is a waveform discontinuity - a click.
	// The steepest jump this -8 dBFS 1 kHz tone can make on its own is about 0.052 per
	// sample; a hard wet-to-dry switch here would jump by 0.257.
	jump := measure_bypass_transition(p)
	check("bypass toggle crossfades instead of clicking", jump, 0.05, 0.05, "")

	fmt.println()
	fmt.println("mix (parallel compression)")
	// Baseline: fully wet at 4:1 is 9 dB of reduction on a -8 dBFS tone.
	set_params(
		p,
		[]Setting{{"Input Trim", 0}, {"Bypass", 0}, {"Threshold", -20}, {"Ratio", 4}, {"Mix", 100}},
	)
	wet := db(run_sine(p, from_db(-8.0), 1000, 1.0))

	set_params(p, []Setting{{"Mix", 0}})
	out = db(run_sine(p, from_db(-8.0), 1000, 1.0))
	check("mix 0% is the dry signal", out, -8, 0.05)

	set_params(p, []Setting{{"Mix", 50}})
	out = db(run_sine(p, from_db(-8.0), 1000, 1.0))
	// Blending happens in the linear domain, so the midpoint is not -12.5 dB.
	expected_mix := db((from_db(-8.0) + from_db(wet)) * 0.5)
	check("mix 50% blends dry and wet", out, expected_mix, 0.15)
	set_params(p, []Setting{{"Mix", 100}})

	fmt.println()
	fmt.println("auto makeup")
	set_params(p, []Setting{{"Auto Makeup", 0}})
	without := db(run_sine(p, from_db(-8.0), 1000, 1.0))
	set_params(p, []Setting{{"Auto Makeup", 1}})
	with := db(run_sine(p, from_db(-8.0), 1000, 1.0))
	// Half the reduction the curve would apply at 0 dBFS: threshold -20, 4:1 -> 15 dB, so 7.5.
	check("auto makeup adds half the curve's 0 dBFS reduction", with - without, 7.5, 0.3)
	set_params(p, []Setting{{"Auto Makeup", 0}})

	fmt.println()
	fmt.println("stereo link")
	// Left at -8 dBFS, right 20 dB quieter and below threshold.
	asymmetric := DEFAULT_RUN
	asymmetric.amplitude = from_db(-8.0)
	asymmetric.right_scale = from_db(-20.0)

	set_params(p, []Setting{{"Stereo Link", 100}})
	left, right := run_stereo(p, asymmetric)
	check("linked: right follows left", db(right) - db(left), -20, 0.3)

	set_params(p, []Setting{{"Stereo Link", 0}})
	left, right = run_stereo(p, asymmetric)
	// Unlinked, the quiet channel is below threshold and keeps its full level, so the
	// channel difference shrinks - the image is pulled toward the quiet side.
	testing_gap := db(right) - db(left)
	check("unlinked: quiet channel is not reduced", db(right), -28, 0.3)
	check("unlinked: image shifts vs linked", testing_gap, -11, 0.5)
	set_params(p, []Setting{{"Stereo Link", 100}})

	fmt.println()
	fmt.println("sidechain")
	// A 50 Hz tone with the detector high-passed at 500 Hz should barely compress.
	set_params(p, []Setting{{"SC High-Pass", 20}})
	unfiltered := db(run_sine(p, from_db(-8.0), 50, 1.0))
	set_params(p, []Setting{{"SC High-Pass", 500}})
	filtered := db(run_sine(p, from_db(-8.0), 50, 1.0))
	check("high-pass keeps low end out of the detector", filtered - unfiltered, 8.9, 0.6)
	set_params(p, []Setting{{"SC High-Pass", 20}})

	// External sidechain: a loud sidechain compresses a quiet main signal.
	ducking := DEFAULT_RUN
	ducking.amplitude = from_db(-30.0) // well below threshold on its own
	ducking.sc_amplitude = from_db(-8.0) // 12 dB over threshold

	set_params(p, []Setting{{"SC Source", 0}})
	internal, _ := run_stereo(p, ducking)
	check("internal source ignores the sidechain port", db(internal), -30, 0.1)

	set_params(p, []Setting{{"SC Source", 1}})
	external, _ := run_stereo(p, ducking)
	check("external source ducks from the sidechain", db(external), -39, 0.6)

	// Input trim stages the main path only. Trimming the signal being compressed must
	// move the output by exactly that much and leave the ducking depth alone, because
	// the external sidechain arrives at the level the DAW routed to it. Fed to both, a
	// +6 dB trim would deepen the reduction by 4.5 dB and the output would move by 1.5.
	// The internal half of this is already covered by "input trim +6 dB" above, where
	// the detector is the main signal and therefore does see the trim.
	set_params(p, []Setting{{"Input Trim", 6}})
	trimmed_external, _ := run_stereo(p, ducking)
	check(
		"input trim does not feed the external sidechain",
		db(trimmed_external) - db(external),
		6,
		0.2,
	)
	set_params(p, []Setting{{"Input Trim", 0}})

	// SC Listen must monitor the detector signal, not the main input.
	set_params(p, []Setting{{"SC Listen", 1}})
	listened, _ := run_stereo(p, ducking)
	check("SC listen outputs the sidechain", db(listened), -8, 0.2)
	set_params(p, []Setting{{"SC Listen", 0}, {"SC Source", 0}})

	// In mid-side the detector is held encoded, so auditioning it has to decode first.
	// A hard-left input encodes to equal mid and side; monitoring that raw would come
	// back centred and 6 dB down instead of hard left.
	hard_left := DEFAULT_RUN
	hard_left.amplitude = from_db(-8.0)
	hard_left.right_scale = 0
	set_params(p, []Setting{{"Ratio", 1}, {"Channel Mode", 1}, {"SC Listen", 1}})
	ms_left, ms_right := run_stereo(p, hard_left)
	check("SC listen decodes mid-side back to L/R", db(ms_left), -8, 0.05)
	check("SC listen keeps a hard-left source hard left", db(ms_right), -200, 0.5)
	set_params(p, []Setting{{"SC Listen", 0}, {"Channel Mode", 0}, {"Ratio", 4}})

	fmt.println()
	fmt.println("mid-side")
	// With no compression, mid-side encode/decode must be lossless.
	set_params(p, []Setting{{"Ratio", 1}, {"Channel Mode", 1}})
	out = db(run_sine(p, from_db(-8.0), 1000, 0.5))
	check("mid-side at 1:1 is transparent", out, -8, 0.01)
	set_params(p, []Setting{{"Channel Mode", 0}, {"Ratio", 4}})

	fmt.println()
	fmt.println("lookahead and latency")
	check("latency at 0 ms lookahead", f64(p.latency.get(p.plugin)), 0, 0, "smp")
	check("impulse delay at 0 ms", f64(measure_impulse_delay(p)), 0, 0, "smp")

	fmt.println()
	fmt.println("port robustness")
	// Hosts may express a disconnected port as a nil buffer, a zero channel count, or
	// a short port array. None of these may crash, and all must leave silence behind -
	// an untouched output buffer would repeat whatever it last held.
	check("no input ports at all writes silence", run_degraded(p, .No_Inputs), -200, 0, "dB")
	check("nil input buffer writes silence", run_degraded(p, .Nil_Input), -200, 0, "dB")
	check("zero-channel input writes silence", run_degraded(p, .Zero_Channels), -200, 0, "dB")

	// A host may also claim events it will not hand over. Surviving this at all is the
	// assertion - a nil dereference here takes the whole host down with it - and the
	// value check confirms nothing was corrupted on the way past.
	{
		holes := holey_events()
		before, after := 0.0, 0.0
		threshold := param_id(p, "Threshold")
		p.params.get_value(p.plugin, threshold, &before)
		p.params.flush(p.plugin, &holes, &sink)
		p.params.get_value(p.plugin, threshold, &after)
		check("flush survives a hole in the event list", after, before, 0, "dB")
	}

	fmt.println()
	fmt.println("event edge cases")
	// The sample loop runs `for frame < frames_count`, so a zero-length block never
	// enters it and an event stamped past the end is never reached. Neither may lose the
	// parameter change: the host has no way to tell that it vanished.
	{
		threshold := param_id(p, "Threshold")
		set_params(p, []Setting{{"Threshold", -20}})

		run_stray_event(p, threshold, -25, 0, 0)
		landed := 0.0
		p.params.get_value(p.plugin, threshold, &landed)
		check("a zero-length block still applies its events", landed, -25, 0.001, "dB")

		run_stray_event(p, threshold, -30, 512, 9999)
		p.params.get_value(p.plugin, threshold, &landed)
		check("an event past the end of the block still applies", landed, -30, 0.001, "dB")

		set_params(p, []Setting{{"Threshold", -20}})
	}

	fmt.println()
	fmt.println("state")
	// A state round trip must preserve the values, and a lookahead loaded while active
	// must announce the latency change - it cannot take effect until reactivation.
	threshold_id := param_id(p, "Threshold")
	lookahead_id := param_id(p, "Lookahead")
	set_params(p, []Setting{{"Threshold", -20}, {"Ratio", 4}, {"Lookahead", 5}})
	saved, saved_ok := save_state(p)
	check("state saves", saved_ok ? 1 : 0, 1, 0, "")

	// Move everything the snapshot holds, so the load has something to restore.
	set_params(p, []Setting{{"Threshold", -33}, {"Ratio", 7.5}, {"Lookahead", 0}})
	latency_changed_count = 0
	check("state loads", load_state(p, saved[:]) ? 1 : 0, 1, 0, "")
	// The load asks the host for a main-thread callback; answer it, the way a host would.
	p.plugin.on_main_thread(p.plugin)

	restored := 0.0
	p.params.get_value(p.plugin, threshold_id, &restored)
	check("threshold restored from state", restored, -20, 0.001, "dB")
	p.params.get_value(p.plugin, lookahead_id, &restored)
	check("lookahead restored from state", restored, 5, 0.001, "ms")
	// Read before anything calls process() or flush(), because those republish the mirror
	// and would hide a load that never did. This is the state a preset loaded on a stopped
	// transport leaves the panel in.
	check("state load republishes the GUI mirror", read_mirror(p, threshold_id), -20, 0.001, "dB")
	// And the staged set has to reach the DSP, not only the mirror. A load that moved the
	// panel but not the audio would be the mirror bug inverted, and just as quiet. No
	// flush in between, deliberately: process() is what has to pick it up. -8 dBFS at the
	// loaded -20/4:1 is 9 dB of reduction; at the -33/7.5:1 it replaced it would be 21.7.
	check(
		"state load reaches the DSP, not just the mirror",
		db(run_sine(p, from_db(-8.0), 1000, 1.0)),
		-17,
		0.6,
	)
	check("latency change announced on load", f64(latency_changed_count), 1, 0, "")
	// CLAP requires the reported latency to stay latched until reactivation, even
	// though the parameter now says otherwise.
	check("reported latency stays latched while active", f64(p.latency.get(p.plugin)), 0, 0, "smp")
	delete(saved)

	// The latched-out value takes effect on the next activation.
	p.plugin.deactivate(p.plugin)
	p.plugin.activate(p.plugin, SR, 1, 512)

	expected_latency := math.round(f64(5.0 / 1000 * SR))
	check("latency at 5 ms lookahead", f64(p.latency.get(p.plugin)), expected_latency, 0, "smp")
	check("tail matches latency", f64(p.tail.get(p.plugin)), expected_latency, 0, "smp")
	check("impulse delay at 5 ms", f64(measure_impulse_delay(p)), expected_latency, 0, "smp")

	p.plugin.deactivate(p.plugin)

	fmt.println()
	fmt.println("port configurations")
	// Mono tracks need a mono layout. The plugin offers one, selection works only while
	// deactivated, the port scan then reports it, and mono audio must compress exactly
	// like stereo did (still threshold -20, ratio 4 from the state round trip above).
	config_count := p.configs.count(p.plugin)
	check("two port configurations", f64(config_count), 2, 0, "")

	config: ext.Audio_Ports_Config
	got_config := p.configs.get(p.plugin, 1, &config)
	mono_io :=
		got_config &&
		config.main_input_channel_count == 1 &&
		config.main_output_channel_count == 1
	check("mono config narrows main in and out to one channel", mono_io ? 1 : 0, 1, 0, "")
	check("mono config keeps the sidechain port", config.input_port_count == 2 ? 1 : 0, 1, 0, "")
	check(
		"mono config selectable while deactivated",
		p.configs.select(p.plugin, config.id) ? 1 : 0,
		1,
		0,
		"",
	)

	port: ext.Audio_Port_Info
	p.ports.get(p.plugin, 0, true, &port)
	check("main input now reports one channel", f64(port.channel_count), 1, 0, "")
	p.ports.get(p.plugin, 0, false, &port)
	check("main output now reports one channel", f64(port.channel_count), 1, 0, "")

	p.plugin.activate(p.plugin, SR, 1, 512)
	check("mono config compresses like stereo", db(run_mono(p, from_db(-8), 1000, 1.0)), -17, 0.6)
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
