package gui

// Mouse handling.
//
// A plain NSView delivers no events to us, so the view has to be a subclass with
// mouseDown:/mouseDragged:/mouseUp: overridden. Odin cannot declare an Objective-C class
// at compile time, so one is built at runtime with objc_allocateClassPair — the same
// mechanism NSApplication and MetalKit use inside core:sys/darwin.
//
// The class carries one indexed ivar: a pointer back to the Gui that owns the view.

import "base:intrinsics"
import "base:runtime"
import NS "core:sys/darwin/Foundation"

VIEW_CLASS_NAME :: "MulticompPanelView"

@(private = "file")
panel_class: NS.Class

// Vertical travel, in points, for a knob to cross its whole range. Roughly a screen's
// worth of movement for full sweep, which is the usual feel.
DRAG_RANGE :: f32(220)
FINE_DIVISOR :: f32(6)

Drag :: struct {
	control:    int, // index into CONTROLS, -1 when idle
    start_y:    f32,
	start_value: f64,
	editing:    bool,
}

// Registered once per process. Re-registering the same class name would fail, and a
// plugin can be instantiated many times in one host.
ensure_view_class :: proc() -> NS.Class {
	if panel_class != nil {
		return panel_class
	}

	existing := NS.objc_lookUpClass(VIEW_CLASS_NAME)
	if existing != nil {
		panel_class = existing
		return panel_class
	}

	super := NS.objc_lookUpClass("NSView")
	if super == nil {
		return nil
	}

	cls := NS.objc_allocateClassPair(super, VIEW_CLASS_NAME, size_of(rawptr))
	if cls == nil {
		return nil
	}

	// "v@:@" is void(id self, SEL cmd, id event); "B@:" is bool(id self, SEL cmd).
	NS.class_addMethod(cls, NS.sel_registerName("mouseDown:"), auto_cast on_mouse_down, "v@:@")
	NS.class_addMethod(cls, NS.sel_registerName("mouseDragged:"), auto_cast on_mouse_dragged, "v@:@")
	NS.class_addMethod(cls, NS.sel_registerName("mouseUp:"), auto_cast on_mouse_up, "v@:@")
	NS.class_addMethod(cls, NS.sel_registerName("isFlipped"), auto_cast is_flipped, "B@:")
	NS.class_addMethod(cls, NS.sel_registerName("acceptsFirstMouse:"), auto_cast accepts_first_mouse, "B@:@")

	NS.objc_registerClassPair(cls)
	panel_class = cls
	return panel_class
}

@(private = "file")
gui_of :: proc "c" (self: NS.id) -> ^Gui {
	slot := (^^Gui)(NS.object_getIndexedIvars(self))
	return slot^
}

bind_view :: proc "c" (view: ^NS.View, g: ^Gui) {
	slot := (^^Gui)(NS.object_getIndexedIvars(NS.id(view)))
	slot^ = g
}

// Flipping the view puts the origin at the top left, which is the coordinate space the
// design and the layout table are already in.
@(private = "file")
is_flipped :: proc "c" (self: NS.id, cmd: NS.SEL) -> bool {
	return true
}

// Without this the first click into an unfocused plugin window is swallowed activating it.
@(private = "file")
accepts_first_mouse :: proc "c" (self: NS.id, cmd: NS.SEL, event: NS.id) -> bool {
	return true
}

@(private = "file")
local_point :: proc "c" (self: NS.id, event: NS.id) -> (x, y: f32) {
	window_point := intrinsics.objc_send(NS.Point, (^Event)(event), "locationInWindow")
	local := intrinsics.objc_send(
		NS.Point,
		(^NS.View)(self),
		"convertPoint:fromView:",
		window_point,
		(^NS.View)(nil),
	)
	return f32(local.x), f32(local.y)
}

@(private = "file")
modifiers_shift :: proc "c" (event: NS.id) -> bool {
	SHIFT_MASK :: 1 << 17 // NSEventModifierFlagShift
	flags := intrinsics.objc_send(u64, (^Event)(event), "modifierFlags")
	return flags & SHIFT_MASK != 0
}

@(private = "file")
click_count :: proc "c" (event: NS.id) -> int {
	return int(intrinsics.objc_send(i64, (^Event)(event), "clickCount"))
}

@(private = "file")
on_mouse_down :: proc "c" (self: NS.id, cmd: NS.SEL, event: NS.id) {
	context = runtime.default_context()
	g := gui_of(self)
	if g == nil || g.bridge.normalized == nil {
		return
	}

	x, y := local_point(self, event)
	index := hit_test(x, y)
	g.drag.control = index
	if index < 0 {
		return
	}

	control := CONTROLS[index]
	param := control.param

	// Double-click restores the factory value, the convention everywhere else in a DAW.
	if click_count(event) >= 2 {
		if g.bridge.reset != nil {
			g.bridge.begin_edit(g.bridge.user, param)
			g.bridge.reset(g.bridge.user, param)
			g.bridge.end_edit(g.bridge.user, param)
		}
		g.drag.control = -1
		return
	}

	switch control.kind {
	case .Button, .Toggle, .Selector:
		// Discrete controls act on press and advance one position, wrapping.
		count := max(2, g.bridge.choices(g.bridge.user, param))
		next := (g.bridge.choice(g.bridge.user, param) + 1) % count
		g.bridge.begin_edit(g.bridge.user, param)
		g.bridge.edit(g.bridge.user, param, f64(next) / f64(count - 1))
		g.bridge.end_edit(g.bridge.user, param)
		g.drag.control = -1

	case .Knob, .Hero:
		g.drag.start_y = y
		g.drag.start_value = g.bridge.normalized(g.bridge.user, param)
		g.drag.editing = true
		g.bridge.begin_edit(g.bridge.user, param)
	}
}

@(private = "file")
on_mouse_dragged :: proc "c" (self: NS.id, cmd: NS.SEL, event: NS.id) {
	context = runtime.default_context()
	g := gui_of(self)
	if g == nil || !g.drag.editing || g.drag.control < 0 {
		return
	}

	_, y := local_point(self, event)
	control := CONTROLS[g.drag.control]

	// Up increases, which is what a vertical drag on a knob should do.
	travel := (g.drag.start_y - y) / DRAG_RANGE
	if modifiers_shift(event) {
		travel /= FINE_DIVISOR
	}

	value := clamp(g.drag.start_value + f64(travel), 0, 1)
	g.bridge.edit(g.bridge.user, control.param, value)
}

@(private = "file")
on_mouse_up :: proc "c" (self: NS.id, cmd: NS.SEL, event: NS.id) {
	context = runtime.default_context()
	g := gui_of(self)
	if g == nil {
		return
	}
	if g.drag.editing && g.drag.control >= 0 {
		g.bridge.end_edit(g.bridge.user, CONTROLS[g.drag.control].param)
	}
	g.drag.editing = false
	g.drag.control = -1
}
