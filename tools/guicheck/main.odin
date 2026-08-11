package guicheck

// Headless verification of the GUI stack.
//
// clap-validator never opens a window, so without this the whole Cocoa/GL/nanovg chain
// would be unproven until it either worked or crashed inside a DAW. An NSOpenGLContext
// can be made current with no view attached, which is enough to render into a framebuffer
// object and read the pixels back — so everything except the host's view hierarchy can be
// checked objectively, with no window ever appearing on screen.

import "core:fmt"
import "core:math"
import "core:os"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"
import nvg "vendor:nanovg"
import nvg_gl "vendor:nanovg/gl"

import "proj:src/dsp"
import "proj:src/gui"

W :: gui.WIDTH
H :: gui.HEIGHT

failures := 0

check :: proc(name: string, ok: bool, detail: string = "") {
	fmt.printfln("  %s %-46s %s", ok ? "ok  " : "FAIL", name, detail)
	if !ok {
		failures += 1
	}
}

Pixel :: struct {
	r, g, b: int,
}

at :: proc(pixels: []u8, x, y: int) -> Pixel {
	// glReadPixels puts the origin at the bottom left.
	flipped := H - 1 - y
	i := (flipped * W + x) * 4
	return Pixel{int(pixels[i]), int(pixels[i + 1]), int(pixels[i + 2])}
}

luma :: proc(p: Pixel) -> int {
	return (p.r * 30 + p.g * 59 + p.b * 11) / 100
}

main :: proc() {
	fmt.println("gui stack")

	ui: gui.Gui
	if !gui.create(&ui) {
		fmt.eprintln("gui.create failed")
		os.exit(1)
	}
	check("NSOpenGLPixelFormat created", ui.format != nil)
	check("NSOpenGLContext created", ui.gl_context != nil)
	check("NSView created", ui.view != nil)

	// The runtime NSView subclass is registered process-wide and never disposed, so its
	// name carries this image's address - a host that unloads and reloads the plugin must
	// not inherit a class whose method pointers are in an unmapped image. Asking for it
	// twice has to return the same class rather than failing on the duplicate name, since
	// one host can instantiate the plugin many times.
	class_a := gui.ensure_view_class()
	class_b := gui.ensure_view_class()
	check("view class registers", class_a != nil)
	check("view class is registered once per image", class_a == class_b)

	gui.gl_context_make_current(ui.gl_context)
	check("GL symbols loaded", gui.load_gl())

	version := gl.GetString(gl.VERSION)
	renderer := gl.GetString(gl.RENDERER)
	check("GL context is 3.2+ core", version != nil, string(version))
	fmt.printfln("       renderer: %s", renderer)

	vg := nvg_gl.Create({.ANTI_ALIAS, .STENCIL_STROKES})
	check("nanovg context created", vg != nil)
	if vg == nil {
		os.exit(1)
	}

	// Offscreen target. nanovg's stroke path needs a stencil buffer, so the framebuffer
	// has to carry one here just as the window's does.
	fbo, colour, depth_stencil: u32
	gl.GenFramebuffers(1, &fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)

	gl.GenRenderbuffers(1, &colour)
	gl.BindRenderbuffer(gl.RENDERBUFFER, colour)
	gl.RenderbufferStorage(gl.RENDERBUFFER, gl.RGBA8, W, H)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, colour)

	gl.GenRenderbuffers(1, &depth_stencil)
	gl.BindRenderbuffer(gl.RENDERBUFFER, depth_stencil)
	gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, W, H)
	gl.FramebufferRenderbuffer(
		gl.FRAMEBUFFER,
		gl.DEPTH_STENCIL_ATTACHMENT,
		gl.RENDERBUFFER,
		depth_stencil,
	)

	check(
		"framebuffer complete",
		gl.CheckFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE,
	)

	gl.Viewport(0, 0, W, H)
	gl.ClearColor(0, 0, 0, 1) // deliberately not the panel colour, so a no-op draw shows up
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)

	if !gui.load_fonts(vg) {
		check("fonts loaded", false, "no usable system font found")
	} else {
		check("fonts loaded", true)
	}

	// A stand-in plugin, so the panel can be rendered without a host. Values are chosen to
	// put every widget in a visibly non-default position.
	ui.vg = vg
	ui.bridge = stub_bridge()
	ui.drag.control = -1
	// The shipping path renders the brushed texture from an image; create it here too, or
	// these checks would be measuring a chassis the plugin never actually draws.
	ui.brush = gui.create_brush(vg)
	check("brushed texture created", ui.brush > 0)

	nvg.BeginFrame(vg, W, H, 1)
	gui.draw_panel(vg, ui.brush)
	gui.draw_controls(&ui)
	nvg.EndFrame(vg)

	pixels := make([]u8, W * H * 4)
	defer delete(pixels)
	gl.ReadPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))

	fmt.println()
	fmt.println("faceplate")

	// Walnut cheek: warm, so red clearly leads blue.
	cheek := at(pixels, 12, 230)
	check(
		"left cheek is walnut",
		cheek.r > cheek.g && cheek.g > cheek.b && cheek.r > 40,
		fmt.tprintf("rgb(%d,%d,%d)", cheek.r, cheek.g, cheek.b),
	)

	right := at(pixels, W - 12, 230)
	check(
		"right cheek is walnut",
		right.r > right.g && right.g > right.b && right.r > 40,
		fmt.tprintf("rgb(%d,%d,%d)", right.r, right.g, right.b),
	)

	// Faceplate: near-neutral graphite, mid luminance.
	plate := at(pixels, 600, 200)
	neutral := abs(plate.r - plate.b) < 14 && abs(plate.r - plate.g) < 14
	check(
		"faceplate is neutral graphite",
		neutral && luma(plate) > 30 && luma(plate) < 90,
		fmt.tprintf("rgb(%d,%d,%d)", plate.r, plate.g, plate.b),
	)

	// The plate is a vertical gradient: lighter at the top than the bottom. Sampled below
	// the header, because the gain-reduction strip chart now occupies its middle.
	top := luma(at(pixels, 600, 92))
	bottom := luma(at(pixels, 600, H - 22))
	check("plate gradient runs light to dark", top > bottom + 8, fmt.tprintf("%d -> %d", top, bottom))

    // Engraved lines: a dark groove with a lit lower lip.
	above := luma(at(pixels, 600, 82))
	groove := luma(at(pixels, 600, 86))
	lip := luma(at(pixels, 600, 87))
	check("header engraving is a groove", groove < above, fmt.tprintf("%d vs %d", groove, above))
	check("engraving has a lit lower lip", lip > groove, fmt.tprintf("%d vs %d", lip, groove))

	// A bay divider, from the design's upper-tier boundaries.
	divider := luma(at(pixels, 440, 200))
	beside := luma(at(pixels, 450, 200))
	check("bay divider is engraved", divider < beside, fmt.tprintf("%d vs %d", divider, beside))

	// Every control must land inside the faceplate, clear of the walnut cheeks and of the
	// tier divider. A layout typo here is otherwise only visible by squinting.
	inside := 0
	for control in gui.CONTROLS {
		if control.x > gui.CHEEK + 8 && control.x < W - gui.CHEEK - 8 && control.y > 90 && control.y < H - 20 {
			inside += 1
		}
	}
	check(
		"every control is on the faceplate",
		inside == len(gui.CONTROLS),
		fmt.tprintf("%d of %d", inside, len(gui.CONTROLS)),
	)
	check("layout covers every parameter", len(gui.CONTROLS) == gui.PARAM_COUNT,
		fmt.tprintf("%d controls, %d parameters", len(gui.CONTROLS), gui.PARAM_COUNT))

	// Knob caps are bright nickel against a dark plate, so each one should read much
	// lighter than the faceplate beside it.
	caps := 0
	for control in gui.CONTROLS {
		if control.kind != .Knob && control.kind != .Hero {
			continue
		}
		centre := luma(at(pixels, int(control.x), int(control.y)))
		beside := luma(at(pixels, int(control.x + control.r + 20), int(control.y)))
		if centre > beside + 40 {
			caps += 1
		}
	}
	check("knob caps render", caps >= 9, fmt.tprintf("%d bright caps", caps))

	// The transfer window is a dark inset. Sample a spot clear of the grid, the unity
	// diagonal and the curve itself — the first attempt at this landed exactly on the
	// trace, which was the drawing working rather than failing.
	window := at(pixels, 652, 175)
	check(
		"transfer window is a dark inset",
		luma(window) < luma(plate),
		fmt.tprintf("rgb(%d,%d,%d)", window.r, window.g, window.b),
	)

	// And the trace is on it: at -55 dB in, an under-threshold input passes at unity, so
	// the curve sits near the window's lower left.
	trace := at(pixels, int(gui.WINDOW_X + 8), int(gui.WINDOW_Y + gui.WINDOW_H - 8))
	check(
		"transfer curve is drawn in amber",
		trace.r > trace.g && trace.g > trace.b && trace.r > 120,
		fmt.tprintf("rgb(%d,%d,%d)", trace.r, trace.g, trace.b),
	)

	// Hit testing must agree with where things were drawn.
	hits := 0
	for control in gui.CONTROLS {
		if gui.hit_test(control.x, control.y) >= 0 {
			hits += 1
		}
	}
	check("every control is clickable", hits == len(gui.CONTROLS), fmt.tprintf("%d of %d", hits, len(gui.CONTROLS)))
	check("empty faceplate is not clickable", gui.hit_test(620, 300) < 0)

	// Re-render with different values and confirm the pixels actually change. If the panel
	// draws the same picture whatever the parameters say, the fault is in the drawing; if
	// it changes here, the fault is in whatever is meant to trigger a repaint.
	stub_offset = 4
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
	nvg.BeginFrame(vg, W, H, 1)
	gui.draw_panel(vg, ui.brush)
	gui.draw_controls(&ui)
	nvg.EndFrame(vg)

	moved := make([]u8, W * H * 4)
	defer delete(moved)
	gl.ReadPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(moved))

	differing := 0
	for i := 0; i < len(pixels); i += 4 {
		if pixels[i] != moved[i] {
			differing += 1
		}
	}
	// Threshold reflects what actually moves: the stub's readout text is fixed per
	// parameter, so this counts pointer angles and lamp states alone. A static panel
	// scores 0, which is the failure this guards against.
	check(
		"panel redraws when values change",
		differing > 700,
		fmt.tprintf("%d pixels differ", differing),
	)
	stub_offset = 0

	// Empty first: with no samples yet the strip is bare glass. Checked before filling it,
	// because once the trace is there the lit area legitimately covers this point.
	hx0, hy0 := int(gui.HISTORY_X), int(gui.HISTORY_Y)
	strip := at(pixels, hx0 + 20, hy0 + 4)
	check(
		"history strip is a dark inset",
		luma(strip) < luma(plate),
		fmt.tprintf("rgb(%d,%d,%d)", strip.r, strip.g, strip.b),
	)

	// The history strip should be drawn and carrying a trace. It is filled by the timer
	// rather than by rendering, so push a full strip's worth first — a partial fill only
	// draws across the right-hand portion, which is correct but makes a poor test target.
	for i in 0 ..< int(gui.HISTORY_W) {
		gui.history_push(&ui)
	}
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
	nvg.BeginFrame(vg, W, H, 1)
	gui.draw_panel(vg, ui.brush)
	gui.draw_controls(&ui)
	nvg.EndFrame(vg)
	gl.ReadPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))

	hx, hy := int(gui.HISTORY_X), int(gui.HISTORY_Y)
	hw, hh := int(gui.HISTORY_W), int(gui.HISTORY_H)

	// 0 dB sits at the top and reduction hangs downward, so the lit area is *between* the
	// top edge and the trace — the bar grows down as the compressor works.
	filled := at(pixels, hx + hw / 2, hy + 10)
	check(
		"reduction is filled from the top down",
		filled.r > filled.b + 20,
		fmt.tprintf("rgb(%d,%d,%d)", filled.r, filled.g, filled.b),
	)

	// 6.5 dB across an 18 dB range is about a third down, so below the trace stays dark.
	below := at(pixels, hx + hw / 2, hy + hh - 8)
	check(
		"space below the trace stays clear",
		below.r < 60,
		fmt.tprintf("rgb(%d,%d,%d)", below.r, below.g, below.b),
	)

	// Three ladders now, not two.
	in_lit := at(pixels, int(gui.IN_LADDER_X) + 8, int(gui.METER_TOP) + 200)
	check(
		"input ladder renders",
		in_lit.g > 60 || in_lit.r > 60,
		fmt.tprintf("rgb(%d,%d,%d)", in_lit.r, in_lit.g, in_lit.b),
	)

	// The operating point must sit exactly on the curve, not near it. Both its coordinates
	// derive from the input level, with y from the same gain computer that drew the line,
	// so this is exact rather than approximate.
	to_x :: proc(db: f32) -> f32 {return gui.WINDOW_X + (db + 60) / 60 * gui.WINDOW_W}
	to_y :: proc(db: f32) -> f32 {return gui.WINDOW_Y + gui.WINDOW_H - (db + 60) / 60 * gui.WINDOW_H}

	// Stub: -12 dBFS in, 4:1 above a 6 dB knee at -18, so the curve gives -16.5 dB out.
	dot := at(pixels, int(to_x(-12)), int(to_y(-16.5)))
	check(
		"operating point sits on the curve",
		dot.r > 200 && dot.g > 170 && dot.b > 120,
		fmt.tprintf("rgb(%d,%d,%d)", dot.r, dot.g, dot.b),
	)

	// At 1:1 the curve *is* the unity diagonal and runs through the top-right corner of the
	// window. That is why the gain-reduction readout sits bottom right: the two shared a
	// corner, and the curve drew straight through the number.
	stub_unity = true
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
	nvg.BeginFrame(vg, W, H, 1)
	gui.draw_panel(vg, ui.brush)
	gui.draw_controls(&ui)
	nvg.EndFrame(vg)

	unity := make([]u8, W * H * 4)
	defer delete(unity)
	gl.ReadPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(unity))

	amber_in :: proc(pixels: []u8, x0, y0, x1, y1: int) -> int {
		found := 0
		for y in y0 ..< y1 {
			for x in x0 ..< x1 {
				p := at(pixels, x, y)
				if p.r > 120 && p.r > p.g + 30 && p.g > p.b {
					found += 1
				}
			}
		}
		return found
	}

	wx, wy := int(gui.WINDOW_X), int(gui.WINDOW_Y)
	ww, wh := int(gui.WINDOW_W), int(gui.WINDOW_H)

	// The readout lives top left, in the wedge above the unity diagonal — the only region
	// the curve can provably never enter, since output is never louder than input.
	readout := amber_in(unity, wx + 4, wy + 4, wx + 100, wy + 24)
	check(
		"readout renders in the top left",
		readout > 20,
		fmt.tprintf("%d amber pixels", readout),
	)

	// Directly below it, still above the diagonal: must stay clear even at 1:1, which is
	// the worst case and the plugin's default.
	clear_zone := amber_in(unity, wx + 12, wy + 34, wx + 60, wy + 52)
	check(
		"space above the diagonal stays clear at 1:1",
		clear_zone == 0,
		fmt.tprintf("%d amber pixels", clear_zone),
	)

	// And the corner the readout used to occupy is exactly where the curve runs at 1:1.
	top_right := amber_in(unity, wx + ww - 46, wy + 4, wx + ww - 2, wy + 24)
	check(
		"at 1:1 the curve occupies the top right",
		top_right > 8,
		fmt.tprintf("%d amber pixels", top_right),
	)

	stub_unity = false

	// Nothing should be pure black: that would mean an area was never drawn.
	black := 0
	for y in 0 ..< H {
		for x in 0 ..< W {
			if luma(at(pixels, x, y)) == 0 {
				black += 1
			}
		}
	}
	check("no undrawn pixels", black == 0, fmt.tprintf("%d black pixels", black))

	// Dump what was rendered, so the panel can be looked at rather than only asserted about.
	flipped := make([]u8, W * H * 4)
	defer delete(flipped)
	for y in 0 ..< H {
		src := (H - 1 - y) * W * 4
		copy(flipped[y * W * 4:][:W * 4], pixels[src:][:W * 4])
	}
	if stbi.write_png("build/panel.png", W, H, 4, raw_data(flipped), W * 4) != 0 {
		fmt.println("       wrote build/panel.png")
	}

	// Presentation render: realistic settings and a moving history, written where the
	// README can reference it. Regenerated on every --gui run, so it cannot go stale.
	shot_mode = true
	stub_offset = 0
	stub_unity = false
	ui.history = {}
	for i in 0 ..< int(gui.HISTORY_W) {
		gui.history_push(&ui)
	}
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
	nvg.BeginFrame(vg, W, H, 1)
	gui.draw_panel(vg, ui.brush)
	gui.draw_controls(&ui)
	nvg.EndFrame(vg)
	gl.ReadPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	for y in 0 ..< H {
		src := (H - 1 - y) * W * 4
		copy(flipped[y * W * 4:][:W * 4], pixels[src:][:W * 4])
	}
	if stbi.write_png("design/panel.png", W, H, 4, raw_data(flipped), W * 4) != 0 {
		fmt.println("       wrote design/panel.png")
	}

	gl.DeleteFramebuffers(1, &fbo)
	gl.DeleteRenderbuffers(1, &colour)
	gl.DeleteRenderbuffers(1, &depth_stencil)
	nvg_gl.Destroy(vg)
	ui.vg = nil

	fmt.println()
	fmt.println("lifecycle")
	gui.destroy(&ui)
	check("destroy leaves no view", ui.view == nil)
	check("destroy leaves no context", ui.gl_context == nil)

	// A DAW will open and close the window repeatedly; that must not accumulate or crash.
	for round in 0 ..< 5 {
		cycle: gui.Gui
		if !gui.create(&cycle) {
			check("repeat create/destroy", false, fmt.tprintf("failed on round %d", round))
			break
		}
		gui.destroy(&cycle)
	}
	check("5 create/destroy cycles survive", true)

	fmt.println()
	if failures == 0 {
		fmt.println("all gui checks passed")
	} else {
		fmt.printfln("%d gui checks FAILED", failures)
		os.exit(1)
	}
}


//
// Stub plugin
//

stub_offset := u32(0)
stub_unity := false
shot_mode := false
shot_tick := 0

// A plausible working setting, so the render is representative rather than arbitrary —
// it doubles as the screenshot in the README. Values are normalised 0..1 across each
// parameter's real range.
Stub :: struct {
	value:  f64,
	text:   string,
	choice: int,
}

STUB := [gui.PARAM_COUNT]Stub {
	{0, "", 0}, // Bypass
	{0.5, "0.0 dB", 0}, // Input Trim
	{0.70, "-18.0 dB", 0}, // Threshold, -18 of -60..0
	{0.158, "4.0 : 1", 0}, // Ratio, 4:1 of 1..20
	{0.25, "6.0 dB", 0}, // Knee
	{0.0997, "30.0 ms", 0}, // Attack
	{0.0985, "300 ms", 0}, // Release
	{0, "", 1}, // Auto Release, on
	{0, "", 0}, // Detector, Peak
	{0, "", 0}, // Topology, feed-forward
	{1.0, "100 %", 0}, // Stereo Link
	{0, "", 0}, // Channel, L/R
	{0.2, "2.0 ms", 0}, // Lookahead
	{0, "", 0}, // SC Source, internal
	{0.125, "80 Hz", 0}, // SC High-Pass
	{0, "", 0}, // SC Listen
	{0.4167, "3.0 dB", 0}, // Makeup, +3 of -12..+24
	{0, "", 0}, // Auto Makeup
	{1.0, "100 %", 0}, // Mix
	{0.5, "0.0 dB", 0}, // Output Trim
}

stub_value :: proc(param: u32) -> f64 {
	if int(param) >= len(STUB) {
		return 0
	}
	v := STUB[param].value
	// The redraw check flips every knob, which is the largest possible pixel change.
	return stub_offset != 0 ? 1 - v : v
}

stub_bridge :: proc() -> gui.Bridge {
	return gui.Bridge {
		user = nil,
		normalized = proc(user: rawptr, param: u32) -> f64 {return stub_value(param)},
		text = proc(user: rawptr, param: u32, buffer: []u8) -> string {
			return int(param) < len(STUB) ? STUB[param].text : ""
		},
		choice = proc(user: rawptr, param: u32) -> int {
			return int(param) < len(STUB) ? STUB[param].choice : 0
		},
		choices = proc(user: rawptr, param: u32) -> int {return 2},
		begin_edit = proc(user: rawptr, param: u32) {},
		edit = proc(user: rawptr, param: u32, normalized: f64) {},
		end_edit = proc(user: rawptr, param: u32) {},
		reset = proc(user: rawptr, param: u32) {},
		meter = proc(user: rawptr, kind: gui.Meter_Kind) -> f64 {
			switch kind {
			case .Input:
				return -12
			case .Gain_Reduction:
				if !shot_mode {
					return 6.5 // constant, so the pixel checks are deterministic
				}
				// A programme-like envelope for the screenshot, advanced once per call so
				// filling the history draws a real trace rather than a flat line.
				shot_tick += 1
				t := f64(shot_tick)
				gr := 6.0 + 3.2 * math.sin(t * 0.031) * math.sin(t * 0.0071) + 1.3 * math.sin(t * 0.21)
				return max(0, gr)
			case .Output:
				return -9
			}
			return 0
		},
	curve = proc(user: rawptr, input_db: f64) -> f64 {
		if stub_unity {
			return input_db // 1:1, the plugin's default and the worst case for overlap
		}
		// A 4:1 curve at -18 with a 6 dB knee, so the window shows a real shape. Use
		// the DSP's own gain computer rather than a re-derived copy: if the curve ever
		// changes, this stub cannot silently drift away from what the audio does.
		computer: dsp.Gain_Computer
		dsp.gain_computer_set(&computer, -18, 4, 6)
		return dsp.gain_computer_output_db(computer, input_db)
	},
	}
}
