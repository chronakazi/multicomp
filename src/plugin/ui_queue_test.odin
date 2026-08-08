package plugin

import "core:testing"

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

	accepted := 0
	for i in 0 ..< UI_QUEUE_CAPACITY * 2 {
		if ui_queue_push(&queue, {kind = .Value, param = u32(i), value = f64(i)}) {
			accepted += 1
		}
	}
	testing.expect_value(t, accepted, UI_QUEUE_CAPACITY)

	// Whatever was accepted must still come back in order. Dropping the newest edit is
	// fine for a control surface — the next mouse move carries a fresher value — but
	// scrambling the ones already queued would not be.
	for i in 0 ..< UI_QUEUE_CAPACITY {
		event, ok := ui_queue_pop(&queue)
		testing.expect(t, ok)
		testing.expect_value(t, event.param, u32(i))
	}
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
