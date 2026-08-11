package plugin

import "base:runtime"

import clap "proj:clap-odin"
import ext "proj:clap-odin/ext"
import "proj:src/dsp"
import "proj:src/gui"

// clap.gui, plus the host timer that drives repainting.
//
// Every callback here is [main-thread]; none of it may touch DSP state directly. From
// Phase 6, parameter edits will travel to the audio thread as events, the same way the
// host's own automation does.

// 60 Hz. The host owns the timer, so we never run a thread of our own — one less thing to
// tear down correctly when a DAW closes the window at an awkward moment.
GUI_TIMER_MS :: 16

gui_ext := ext.Plugin_Gui {
	is_api_supported = proc "c" (plugin: ^clap.Plugin, api: cstring, is_floating: bool) -> bool {
		context = runtime.default_context()
		// Embedded Cocoa only: a floating window would be the host's to manage.
		return string(api) == ext.WINDOW_API_COCOA && !is_floating
	},

	get_preferred_api = proc "c" (
		plugin: ^clap.Plugin,
		api: ^cstring,
		is_floating: ^bool,
	) -> bool {
		api^ = ext.WINDOW_API_COCOA
		is_floating^ = false
		return true
	},

	create = proc "c" (plugin: ^clap.Plugin, api: cstring, is_floating: bool) -> bool {
		context = runtime.default_context()
		if string(api) != ext.WINDOW_API_COCOA || is_floating {
			return false
		}

		self := from_plugin(plugin)
		self.ui.bridge = make_bridge(self)
		if !gui.create(&self.ui) {
			return false
		}

		// Ask the host to tick us. If it does not support timers the window still opens,
		// it simply will not animate — better than refusing to show at all.
		if self.host_timer != nil && self.host_timer.register_timer != nil {
			if self.host_timer.register_timer(self.host, GUI_TIMER_MS, &self.timer_id) {
				self.timer_running = true
			}
		}
		return true
	},

	destroy = proc "c" (plugin: ^clap.Plugin) {
		context = runtime.default_context()
		gui_teardown(from_plugin(plugin))
	},

	set_scale = proc "c" (plugin: ^clap.Plugin, scale: f64) -> bool {
		// Honest refusal: the panel is a fixed 1180x460 and would not honour a host
		// scale, so claiming success would just show a wrongly sized window. GUI
		// resize (Phase 8) revisits this. Retina backing is handled separately, per
		// frame, from the view's backingScaleFactor.
		return false
	},

	get_size = proc "c" (plugin: ^clap.Plugin, width, height: ^u32) -> bool {
		width^ = gui.WIDTH
		height^ = gui.HEIGHT
		return true
	},

	// Fixed size until Phase 8. Saying so plainly keeps hosts from drawing resize grips
	// that do nothing.
	can_resize = proc "c" (plugin: ^clap.Plugin) -> bool {
		return false
	},

	get_resize_hints = proc "c" (plugin: ^clap.Plugin, hints: ^ext.Gui_Resize_Hints) -> bool {
		return false
	},

	adjust_size = proc "c" (plugin: ^clap.Plugin, width, height: ^u32) -> bool {
		width^ = gui.WIDTH
		height^ = gui.HEIGHT
		return true
	},

	set_size = proc "c" (plugin: ^clap.Plugin, width, height: u32) -> bool {
		// Not resizable, so only the one size is acceptable.
		return width == gui.WIDTH && height == gui.HEIGHT
	},

	set_parent = proc "c" (plugin: ^clap.Plugin, window: ^ext.Window) -> bool {
		context = runtime.default_context()
		if window == nil {
			return false
		}
		self := from_plugin(plugin)
		return gui.attach(&self.ui, window.cocoa)
	},

	set_transient = proc "c" (plugin: ^clap.Plugin, window: ^ext.Window) -> bool {
		return false // embedded only
	},

	suggest_title = proc "c" (plugin: ^clap.Plugin, title: cstring) {},

	show = proc "c" (plugin: ^clap.Plugin) -> bool {
		context = runtime.default_context()
		self := from_plugin(plugin)
		gui.set_visible(&self.ui, true)
		gui.render(&self.ui) // paint immediately rather than waiting for the first tick
		return true
	},

	hide = proc "c" (plugin: ^clap.Plugin) -> bool {
		context = runtime.default_context()
		self := from_plugin(plugin)
		gui.set_visible(&self.ui, false)
		return true
	},
}

// Releases the window and stops both clocks. Idempotent, because it is reached from two
// directions: the host destroying the GUI, and the plugin being destroyed with the GUI
// still up. The second is a host contract violation, but the consequence of not handling
// it is that the run-loop NSTimer keeps firing `tick:` into a freed Multicomp.
gui_teardown :: proc(self: ^Multicomp) {
	if self.timer_running && self.host_timer != nil && self.host_timer.unregister_timer != nil {
		self.host_timer.unregister_timer(self.host, self.timer_id)
	}
	self.timer_running = false

	gui.destroy(&self.ui)
}

//
// clap.timer-support
//

timer_ext := ext.Plugin_Timer_Support {
	on_timer = proc "c" (plugin: ^clap.Plugin, timer_id: clap.Clap_Id) {
		context = runtime.default_context()
		self := from_plugin(plugin)
		if self.timer_running && timer_id == self.timer_id {
			gui.tick_from_host(&self.ui)
		}
	},
}


//
// The bridge the panel talks to
//

make_bridge :: proc(self: ^Multicomp) -> gui.Bridge {
	return gui.Bridge {
		user = self,
		normalized = proc(user: rawptr, param: u32) -> f64 {
			self := (^Multicomp)(user)
			if !is_valid_param(param) {
				return 0
			}
			id := Param_Id(param)
			p := PARAMS[id]
			value := read_published(&self.mirror[id])
			if p.max <= p.min {
				return 0
			}
			return clamp((value - p.min) / (p.max - p.min), 0, 1)
		},

		text = proc(user: rawptr, param: u32, buffer: []u8) -> string {
			self := (^Multicomp)(user)
			if !is_valid_param(param) {
				return ""
			}
			id := Param_Id(param)
			return format_param(PARAMS[id], read_published(&self.mirror[id]), buffer)
		},

		choice = proc(user: rawptr, param: u32) -> int {
			self := (^Multicomp)(user)
			if !is_valid_param(param) {
				return 0
			}
			id := Param_Id(param)
			return choice_index(PARAMS[id], read_published(&self.mirror[id]))
		},

		choices = proc(user: rawptr, param: u32) -> int {
			if !is_valid_param(param) {
				return 2
			}
			p := PARAMS[Param_Id(param)]
			if len(p.choices) > 0 {
				return len(p.choices)
			}
			return int(p.max - p.min) + 1
		},

		begin_edit = proc(user: rawptr, param: u32) {
			self := (^Multicomp)(user)
			ui_queue_push(&self.ui_queue, {kind = .Gesture_Begin, param = param})
			request_flush(self)
		},

		edit = proc(user: rawptr, param: u32, normalized: f64) {
			self := (^Multicomp)(user)
			if !is_valid_param(param) {
				return
			}
			id := Param_Id(param)
			p := PARAMS[id]
			value := clamp_param(id, p.min + normalized * (p.max - p.min))

			// Publish immediately so the knob tracks the mouse even when the host is not
			// processing audio; the audio thread will land on the same value. Only on a
			// successful push, though - a dropped edit must not leave the mirror showing
			// a value the DSP never applied.
			if ui_queue_push(&self.ui_queue, {kind = .Value, param = param, value = value}) {
				publish(&self.mirror[id], value)
			}
			request_flush(self)
		},

		end_edit = proc(user: rawptr, param: u32) {
			self := (^Multicomp)(user)
			ui_queue_push(&self.ui_queue, {kind = .Gesture_End, param = param})
			request_flush(self)
		},

		reset = proc(user: rawptr, param: u32) {
			self := (^Multicomp)(user)
			if !is_valid_param(param) {
				return
			}
			id := Param_Id(param)
			value := PARAMS[id].default
			if ui_queue_push(&self.ui_queue, {kind = .Value, param = param, value = value}) {
				publish(&self.mirror[id], value)
			}
			request_flush(self)
		},

		meter = proc(user: rawptr, kind: gui.Meter_Kind) -> f64 {
			self := (^Multicomp)(user)
			switch kind {
			case .Input:
				return read_published(&self.meter_in)
			case .Gain_Reduction:
				return read_published(&self.meter_gr)
			case .Output:
				return read_published(&self.meter_out)
			}
			return 0
		},

		curve = proc(user: rawptr, input_db: f64) -> f64 {
			self := (^Multicomp)(user)
			// Built from the mirrored parameters rather than read from the band: the
			// audio thread owns the band's computer, and reading it here would be a
			// torn-read race. The mirror is atomic, so the window always shows a real
			// curve - never a half-updated one.
			computer := make_curve(
				read_published(&self.mirror[.Threshold]),
				read_published(&self.mirror[.Ratio]),
				read_published(&self.mirror[.Knee]),
			)
			return dsp.gain_computer_output_db(computer, input_db)
		},
	}
}

// A parameter edit is useless until the audio thread drains it, and a host that is idle
// may not call process() at all. clap.params.request_flush is the documented way to ask
// for a flush; without it, moving a knob on a stopped transport would do nothing.
request_flush :: proc(self: ^Multicomp) {
	if self.host_params != nil && self.host_params.request_flush != nil {
		self.host_params.request_flush(self.host)
	}
}
