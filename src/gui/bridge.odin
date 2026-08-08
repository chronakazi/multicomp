package gui

// The seam between the panel and the plugin.
//
// `gui/` never imports the CLAP bindings or the plugin package — the same rule that keeps
// `dsp/` testable. Everything the panel needs from the plugin arrives through this vtable,
// which `plugin/gui.odin` fills in. Parameters are addressed by their numeric CLAP id, so
// this file needs no knowledge of Param_Id.
//
// Every one of these is called on the main thread, from inside a render or an event.

Meter_Kind :: enum {
	Input, // input peak after trim, dBFS — the transfer window's x axis
	Gain_Reduction, // dB of reduction, positive
	Output, // output peak, dBFS
}

Bridge :: struct {
	user:       rawptr,

	// Current value mapped to 0..1 across the parameter's range, for knob rotation.
	normalized: proc(user: rawptr, param: u32) -> f64,

	// Formatted for display, written into the caller's buffer.
	text:       proc(user: rawptr, param: u32, buffer: []u8) -> string,

	// Index of the selected option, for toggles and selectors.
	choice:     proc(user: rawptr, param: u32) -> int,

	// Number of discrete positions, so a click can advance to the next one.
	choices:    proc(user: rawptr, param: u32) -> int,

	// A drag is bracketed by begin_edit/end_edit so the host can record it as one
	// automation gesture rather than a scatter of unrelated values.
	begin_edit: proc(user: rawptr, param: u32),
	edit:       proc(user: rawptr, param: u32, normalized: f64),
	end_edit:   proc(user: rawptr, param: u32),

	// Double-click restores the factory value.
	reset:      proc(user: rawptr, param: u32),

	meter:      proc(user: rawptr, kind: Meter_Kind) -> f64,

	// The static curve, so the transfer window shows the real one rather than a redrawn
	// approximation that could drift from the DSP.
	curve:      proc(user: rawptr, input_db: f64) -> f64,
}
