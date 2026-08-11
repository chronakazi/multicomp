package gui

// The plugin window: a child NSView under the host's parent view, with an OpenGL context
// and nanovg drawing into it.
//
// This package owns no CLAP types. `plugin/gui.odin` translates clap.gui calls into the
// handful of entry points below, which keeps the Cocoa and GL work testable in isolation
// and mirrors how dsp/ is kept free of CLAP.
//
// Everything here is main-thread only. CLAP marks the whole of clap.gui [main-thread],
// and Cocoa would not tolerate anything else.

import NS "core:sys/darwin/Foundation"

import gl "vendor:OpenGL"
import nvg "vendor:nanovg"
import nvg_gl "vendor:nanovg/gl"

// Fixed for now; Phase 8 makes the window resizable. These are the dimensions the
// faceplate in design/panel.html is drawn at, so its coordinates transfer unchanged.
WIDTH :: 1180
HEIGHT :: 460

Gui :: struct {
	view:       ^NS.View,
	gl_context: ^Gl_Context,
	format:     ^Pixel_Format,
	vg:         ^nvg.Context,
	attached:   bool,
	visible:    bool,
	fonts_ok:   bool,
	// Tiled striation texture for the chassis. Belongs to `vg`, so it is created with it
	// and freed with it; 0 means "not created", which draw_panel strokes instead.
	brush:      int,
	bridge:     Bridge,
	drag:       Drag,

	// Repaint is driven by the host's clap.timer-support when it has one. Not every host
	// does, and a host may register a timer and then never tick it — which leaves a
	// perfectly correct panel frozen on its first frame. `fallback_timer` covers that,
	// standing down whenever host ticks are actually arriving.
	host_ticks:     u32,
	seen_ticks:     u32,
	fallback_timer: ^Timer,

	// Last backing scale rendered at, so a window migrating between Retina and
	// non-Retina displays triggers a drawable update.
	last_backing:   f32,

	history:        History,
}

// One gain-reduction sample per timer tick, so the strip chart scrolls at a steady rate.
// Sampling in `render` instead would make it lurch, because a drag repaints far more often
// than the timer fires.
History :: struct {
	samples: [int(HISTORY_W)]f32,
	write:   int,
	filled:  int,
}

history_push :: proc(g: ^Gui) {
	if g.bridge.meter == nil {
		return
	}
	g.history.samples[g.history.write] = f32(g.bridge.meter(g.bridge.user, .Gain_Reduction))
	g.history.write = (g.history.write + 1) % len(g.history.samples)
	if g.history.filled < len(g.history.samples) {
		g.history.filled += 1
	}
}

// Driven by clap.timer-support.
tick_from_host :: proc(g: ^Gui) {
	g.host_ticks += 1
	history_push(g)
	render(g)
}

// Driven by our own run-loop timer.
tick_fallback :: proc(g: ^Gui) {
	if g.host_ticks != g.seen_ticks {
		g.seen_ticks = g.host_ticks // the host is driving; one repaint a frame is enough
		return
	}
	history_push(g)
	render(g)
}

// Builds the view and GL context. The context has no drawable until `attach` gives it a
// view that lives in a window, so nanovg is deliberately not created here.
create :: proc(g: ^Gui) -> bool {
	attributes := [?]u32 {
		PFA_OPENGL_PROFILE,
		PROFILE_VERSION_3_2_CORE,
		PFA_COLOR_SIZE,
		24,
		PFA_ALPHA_SIZE,
		8,
		PFA_DEPTH_SIZE,
		24,
		// nanovg's STENCIL_STROKES path needs a stencil buffer; without one, overlapping
		// strokes double-darken where they cross.
		PFA_STENCIL_SIZE,
		8,
		PFA_DOUBLE_BUFFER,
		PFA_ACCELERATED,
		PFA_NO_RECOVERY,
		0,
	}

	g.visible = false
	g.attached = false
	g.drag.control = -1
	g.brush = 0

	g.format = pixel_format_create(raw_data(attributes[:]))
	if g.format == nil {
		return false
	}

	g.gl_context = gl_context_create(g.format)
	if g.gl_context == nil {
		destroy(g)
		return false
	}

	// A subclassed view, so mouse events reach us at all.
	class := ensure_view_class()
	if class == nil {
		destroy(g)
		return false
	}
	g.view = view_create_of_class(class, NS.Rect{{0, 0}, {NS.Float(WIDTH), NS.Float(HEIGHT)}})
	if g.view == nil {
		destroy(g)
		return false
	}
	bind_view(g.view, g)
	view_set_hidden(g.view, true)
	return true
}

// 60 Hz, matching the host timer we ask for.
FALLBACK_TIMER_S :: 1.0 / 60.0

destroy :: proc(g: ^Gui) {
	// Invalidate before releasing the view: NSTimer retains its target.
	timer_invalidate(g.fallback_timer)
	g.fallback_timer = nil

	if g.vg != nil {
		// Deleting GL objects requires the context that owns them to be current.
		if g.gl_context != nil {
			gl_context_make_current(g.gl_context)
		}
		nvg_gl.Destroy(g.vg)
		g.vg = nil
		g.brush = 0 // the image belonged to that context; the handle is meaningless now
	}

	if g.gl_context != nil {
		gl_context_set_view(g.gl_context, nil)
		gl_context_clear_current()
	}

	if g.view != nil {
		view_remove_from_superview(g.view)
		release(g.view)
		g.view = nil
	}

	release(g.gl_context)
	g.gl_context = nil
	release(g.format)
	g.format = nil

	g.attached = false
	g.visible = false
}

// `parent` is the host's NSView, straight out of clap_window.cocoa.
attach :: proc(g: ^Gui, parent: rawptr) -> bool {
	if g.view == nil || parent == nil {
		return false
	}

	// A host may call set_parent more than once - re-parenting, or simply being thorough.
	// addSubview on a view that already has a superview would install it twice. Removing
	// first is a no-op when there is no superview, and our own reference from
	// class_createInstance keeps the view alive across the swap.
	view_remove_from_superview(g.view)
	NS.View_addSubview((^NS.View)(parent), g.view)

	if g.fallback_timer == nil {
		g.fallback_timer = timer_schedule(g.view, NS.sel_registerName("tick:"), FALLBACK_TIMER_S)
	}
	// Only meaningful once the view is in a window, which is why it happens here rather
	// than in create().
	gl_context_set_view(g.gl_context, g.view)
	gl_context_update(g.gl_context)
	g.attached = true
	return true
}

set_visible :: proc(g: ^Gui, visible: bool) {
	g.visible = visible
	if g.view != nil {
		view_set_hidden(g.view, !visible)
	}
}

set_size :: proc(g: ^Gui, width, height: u32) {
	if g.view == nil {
		return
	}
	view_set_frame(g.view, NS.Rect{{0, 0}, {NS.Float(width), NS.Float(height)}})
	if g.gl_context != nil {
		gl_context_update(g.gl_context)
	}
}

// Called from the host's timer. Cheap to call when nothing is up yet.
render :: proc(g: ^Gui) {
	if !g.attached || !g.visible || g.gl_context == nil {
		return
	}

	gl_context_make_current(g.gl_context)

	if g.vg == nil {
		if !load_gl() {
			return
		}
		g.vg = nvg_gl.Create({.ANTI_ALIAS, .STENCIL_STROKES})
		if g.vg == nil {
			return
		}
		g.fonts_ok = load_fonts(g.vg)
		g.brush = create_brush(g.vg)
	}

	// nanovg works in points and scales its own geometry; the GL viewport is in pixels.
	// If the backing scale changed - the host window moved across displays - the
	// drawable is stale and must be re-sized before the viewport is set from it.
	backing := view_backing_scale(g.view)
	if backing != g.last_backing {
		gl_context_update(g.gl_context)
		g.last_backing = backing
	}
	gl.Viewport(0, 0, i32(f32(WIDTH) * backing), i32(f32(HEIGHT) * backing))

	gl.ClearColor(PANEL_CLEAR.r, PANEL_CLEAR.g, PANEL_CLEAR.b, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)

	nvg.BeginFrame(g.vg, WIDTH, HEIGHT, backing)
	draw_panel(g.vg, g.brush)
	if g.fonts_ok {
		draw_controls(g)
	}
	nvg.EndFrame(g.vg)

	gl_context_flush(g.gl_context)
}
