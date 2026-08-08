package gui

// Cocoa bindings for the pieces of AppKit we need that Odin does not already bind.
//
// `core:sys/darwin/Foundation` gives us NSView, but not NSOpenGLContext or
// NSOpenGLPixelFormat, so those are declared here with the same `@(objc_class)` +
// `intrinsics.objc_send` pattern the standard library uses. Foundation's own `msgSend`
// is package-private, so we call the intrinsic directly.

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

// No `foreign import` of AppKit or OpenGL here, deliberately. Odin only emits a link flag
// for a framework that a `foreign` block actually declares procedures in, so importing
// them without one is dead weight that reads as linkage but is not (`otool -L` confirms).
// The NSOpenGL* classes come from Cocoa, which Foundation already links, and the GL entry
// points are resolved by name at runtime — see gl_loader.odin.

// objc_send needs a receiver whose type carries @(objc_class); a bare NS.id will not do,
// so NSEvent gets a minimal binding of its own.
@(objc_class = "NSEvent")
Event :: struct {
	using _: NS.Object,
}

@(objc_class = "NSOpenGLPixelFormat")
Pixel_Format :: struct {
	using _: NS.Object,
}

@(objc_class = "NSOpenGLContext")
Gl_Context :: struct {
	using _: NS.Object,
}

// NSOpenGLPixelFormatAttribute values, from AppKit's NSOpenGL.h. They are a flat
// NULL-terminated list of tokens, some followed by a value.
PFA_DOUBLE_BUFFER :: 5
PFA_COLOR_SIZE :: 8
PFA_ALPHA_SIZE :: 11
PFA_DEPTH_SIZE :: 12
PFA_STENCIL_SIZE :: 13
PFA_ACCELERATED :: 73
PFA_NO_RECOVERY :: 72
PFA_OPENGL_PROFILE :: 99

// nanovg's Odin port defaults to its GL3 backend, whose shaders are `#version 150 core`,
// so the context has to be a 3.2 core profile. A legacy context silently fails to compile
// them.
PROFILE_VERSION_3_2_CORE :: 0x3200

//
// NSOpenGLPixelFormat
//

pixel_format_create :: proc "c" (attributes: [^]u32) -> ^Pixel_Format {
	self := intrinsics.objc_send(^Pixel_Format, Pixel_Format, "alloc")
	return intrinsics.objc_send(^Pixel_Format, self, "initWithAttributes:", attributes)
}

//
// NSOpenGLContext
//

gl_context_create :: proc "c" (format: ^Pixel_Format) -> ^Gl_Context {
	self := intrinsics.objc_send(^Gl_Context, Gl_Context, "alloc")
	return intrinsics.objc_send(
		^Gl_Context,
		self,
		"initWithFormat:shareContext:",
		format,
		(^Gl_Context)(nil),
	)
}

gl_context_set_view :: proc "c" (self: ^Gl_Context, view: ^NS.View) {
	intrinsics.objc_send(nil, self, "setView:", view)
}

gl_context_make_current :: proc "c" (self: ^Gl_Context) {
	intrinsics.objc_send(nil, self, "makeCurrentContext")
}

gl_context_clear_current :: proc "c" () {
	intrinsics.objc_send(nil, Gl_Context, "clearCurrentContext")
}

// Must be called after the view moves or resizes, or the context keeps rendering at the
// old drawable size.
gl_context_update :: proc "c" (self: ^Gl_Context) {
	intrinsics.objc_send(nil, self, "update")
}

gl_context_flush :: proc "c" (self: ^Gl_Context) {
	intrinsics.objc_send(nil, self, "flushBuffer")
}

//
// NSView additions
//

view_create :: proc "c" (frame: NS.Rect) -> ^NS.View {
	self := intrinsics.objc_send(^NS.View, NS.View, "alloc")
	return intrinsics.objc_send(^NS.View, self, "initWithFrame:", frame)
}

// Instantiates a runtime-registered subclass. `alloc` cannot be messaged to a Class value
// held in a variable, so this uses the runtime function alloc is built on. extraBytes is 0
// because the indexed ivar space was already reserved in objc_allocateClassPair.
view_create_of_class :: proc "c" (class: NS.Class, frame: NS.Rect) -> ^NS.View {
	instance := NS.class_createInstance(class, 0)
	if instance == nil {
		return nil
	}
	return intrinsics.objc_send(^NS.View, (^NS.View)(instance), "initWithFrame:", frame)
}

view_set_frame :: proc "c" (self: ^NS.View, frame: NS.Rect) {
	intrinsics.objc_send(nil, self, "setFrame:", frame)
}

view_remove_from_superview :: proc "c" (self: ^NS.View) {
	intrinsics.objc_send(nil, self, "removeFromSuperview")
}

view_set_hidden :: proc "c" (self: ^NS.View, hidden: bool) {
	intrinsics.objc_send(nil, self, "setHidden:", NS.BOOL(hidden))
}

// nil until the view has been added to a window's hierarchy.
view_window :: proc "c" (self: ^NS.View) -> rawptr {
	return intrinsics.objc_send(rawptr, self, "window")
}

// 1.0 on a standard display, 2.0 on Retina. Returns 1 when the view is not yet in a
// window, which is the right fallback for the first frame after attaching.
view_backing_scale :: proc "c" (self: ^NS.View) -> f32 {
	window := view_window(self)
	if window == nil {
		return 1
	}
	scale := intrinsics.objc_send(NS.Float, (^NS.Object)(window), "backingScaleFactor")
	return scale > 0 ? f32(scale) : 1
}

release :: proc "c" (object: rawptr) {
	if object != nil {
		intrinsics.objc_send(nil, (^NS.Object)(object), "release")
	}
}
