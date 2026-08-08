package gui

// `vendor:OpenGL` is a function-pointer loader with no platform linkage of its own, so
// somebody has to hand it addresses. On macOS the OpenGL symbols live in the framework
// binary, which we resolve by name once at startup.

import "core:dynlib"
import gl "vendor:OpenGL"

OPENGL_FRAMEWORK :: "/System/Library/Frameworks/OpenGL.framework/OpenGL"

// macOS tops out at a 4.1 core profile; 3.3 is comfortably above what nanovg's GL3
// backend needs and avoids asking for entry points this platform will never have.
GL_MAJOR :: 3
GL_MINOR :: 3

@(private = "file")
opengl_library: dynlib.Library

@(private = "file")
loaded: bool

// Idempotent: the GL context must be current before this is called, and calling it again
// after that is harmless.
load_gl :: proc() -> bool {
	if loaded {
		return true
	}

	library, ok := dynlib.load_library(OPENGL_FRAMEWORK)
	if !ok {
		return false
	}
	opengl_library = library

	gl.load_up_to(GL_MAJOR, GL_MINOR, set_proc_address)
	loaded = true
	return true
}

@(private = "file")
set_proc_address :: proc(p: rawptr, name: cstring) {
	address, found := dynlib.symbol_address(opengl_library, string(name))
	if !found {
		address = nil // leave the slot nil rather than stale; unused entry points are fine
	}
	(^rawptr)(p)^ = address
}
