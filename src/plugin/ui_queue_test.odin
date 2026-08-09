package plugin

import "base:runtime"
import "core:testing"

import clap "proj:clap-odin"

// Run with:  odin test src/plugin
//
// The ring buffer is the one piece of cross-thread machinery in the plugin, and its
// failure mode under wrap-around is silent: edits arrive out of order or vanish, which
// looks like a flaky knob rather than a data structure bug.

@(test)
ui_queue_preserves_order :: proc(t: ^testing.T) {
	queue: Ui_Queue

	for i in 0 ..< 32 {
		testing.expect(t, ui_queue_push(&queue, {kind = .Value, param = u32(i), value = f64(i)}))
	}
	for i in 0 ..< 32 {
		event, ok := ui_queue_pop(&queue)
		testing.expect(t, ok, "queue should still hold events")
		testing.expect_value(t, event.param, u32(i))
		testing.expect_value(t, event.value, f64(i))
	}

	_, empty := ui_queue_pop(&queue)
	testing.expect(t, !empty, "queue should be drained")
}

@(test)
ui_queue_survives_wraparound :: proc(t: ^testing.T) {
	queue: Ui_Queue

	// Push and drain many times the capacity, so the indices wrap repeatedly. A mask that
	// is wrong, or indices that are compared rather than subtracted, breaks here.
	expected := 0
	for round in 0 ..< 40 {
		for _ in 0 ..< 37 {
			ui_queue_push(&queue, {kind = .Value, param = u32(expected), value = f64(expected)})
			expected += 1
		}
		for _ in 0 ..< 37 {
			event, ok := ui_queue_pop(&queue)
			testing.expectf(t, ok, "empty on round %d", round)
			if ok {
				testing.expect_value(t, event.value, f64(event.param))
			}
		}
	}
}

@(test)
ui_queue_drops_when_full_without_corrupting :: proc(t: ^testing.T) {
	queue: Ui_Queue

	// Values stop short of full by the gesture reserve; gestures must still fit, or an
	// end could be dropped and the host's automation gesture would stay open forever.
	accepted := 0
	for i in 0 ..< UI_QUEUE_CAPACITY * 2 {
		if ui_queue_push(&queue, {kind = .Value, param = u32(i), value = f64(i)}) {
			accepted += 1
		}
	}
	testing.expect_value(t, accepted, UI_QUEUE_CAPACITY - UI_QUEUE_GESTURE_RESERVE)

	gestures := 0
	for i in 0 ..< UI_QUEUE_CAPACITY {
		if ui_queue_push(&queue, {kind = .Gesture_Begin, param = u32(i)}) {
			gestures += 1
		}
	}
	testing.expect_value(t, gestures, UI_QUEUE_GESTURE_RESERVE)

	// Whatever was accepted must still come back in order. Dropping the newest edit is
	// fine for a control surface — the next mouse move carries a fresher value — but
	// scrambling the ones already queued would not be.
	for i in 0 ..< UI_QUEUE_CAPACITY - UI_QUEUE_GESTURE_RESERVE {
		event, ok := ui_queue_pop(&queue)
		testing.expect(t, ok)
		testing.expect_value(t, event.param, u32(i))
	}
	for _ in 0 ..< UI_QUEUE_GESTURE_RESERVE {
		event, ok := ui_queue_pop(&queue)
		testing.expect(t, ok)
		testing.expect(t, event.kind == .Gesture_Begin)
	}
}

@(test)
drain_ui_coalesces_value_runs :: proc(t: ^testing.T) {
	// A drag enqueues one value per mouse event; the drain must collapse a run of edits
	// to one control into the newest, while leaving gestures and other parameters'
	// values in place and in order.
	Captured :: struct {
		kind:    Ui_Event_Kind,
		param:   u32,
		value:   f64,
	}

	captured: [dynamic]Captured
	defer delete(captured)
	out_events := clap.Output_Events {
		ctx = &captured,
		try_push = proc "c" (out: ^clap.Output_Events, header: ^clap.Event_Header) -> bool {
			context = runtime.default_context()
			target := cast(^[dynamic]Captured)out.ctx
			#partial switch clap.Event_Type(header.type) {
			case .PARAM_VALUE:
				event := (^clap.Event_Param_Value)(header)
				append(target, Captured{kind = .Value, param = event.param_id, value = event.value})
			case .PARAM_GESTURE_BEGIN:
				event := (^clap.Event_Param_Gesture)(header)
				append(target, Captured{kind = .Gesture_Begin, param = event.param_id})
			case .PARAM_GESTURE_END:
				event := (^clap.Event_Param_Gesture)(header)
				append(target, Captured{kind = .Gesture_End, param = event.param_id})
			}
			return true
		},
	}

	self: Multicomp
	threshold := u32(Param_Id.Threshold)
	ratio := u32(Param_Id.Ratio)

	ui_queue_push(&self.ui_queue, {kind = .Gesture_Begin, param = threshold})
	ui_queue_push(&self.ui_queue, {kind = .Value, param = threshold, value = -10})
	ui_queue_push(&self.ui_queue, {kind = .Value, param = threshold, value = -20})
	ui_queue_push(&self.ui_queue, {kind = .Value, param = threshold, value = -30})
	ui_queue_push(&self.ui_queue, {kind = .Value, param = ratio, value = 4})
	ui_queue_push(&self.ui_queue, {kind = .Value, param = threshold, value = -25})
	ui_queue_push(&self.ui_queue, {kind = .Gesture_End, param = threshold})

	drain_ui(&self, &out_events)

	// The three-value run collapses to its newest member; the values of another
	// parameter interleaved with it, and the later single edit, pass through untouched.
	expected := [?]Captured{
		{kind = .Gesture_Begin, param = threshold},
		{kind = .Value, param = threshold, value = -30},
		{kind = .Value, param = ratio, value = 4},
		{kind = .Value, param = threshold, value = -25},
		{kind = .Gesture_End, param = threshold},
	}
	if !testing.expect_value(t, len(captured), len(expected)) {
		return
	}
	for want, i in expected {
		testing.expect_value(t, captured[i].kind, want.kind)
		testing.expect_value(t, captured[i].param, want.param)
		if want.kind == .Value {
			testing.expect_value(t, captured[i].value, want.value)
		}
	}

	// And the applied state reflects exactly the echoed values: the run landed on its
	// newest member, and the later single edit overrode it.
	testing.expect_value(t, self.values[.Threshold], -25)
	testing.expect_value(t, self.values[.Ratio], 4)
}

@(test)
published_values_round_trip_exactly :: proc(t: ^testing.T) {
	// The mirror carries f64 bits through a u64 atomic; that must be lossless, including
	// for negative and fractional values.
	slot: u64
	for value in ([?]f64{0, 1, -18.5, 0.1, -60, 3000, 1e-9, -0.0}) {
		publish(&slot, value)
		testing.expect_value(t, read_published(&slot), value)
	}
}
