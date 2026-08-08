package plugin

import "base:intrinsics"

import clap "proj:clap-odin"

// Single-producer, single-consumer ring buffer carrying edits from the GUI to the audio
// thread.
//
// The GUI must never write DSP state directly. Everything it does travels through here,
// gets applied in `process`/`flush`, and is echoed to the host on `out_events` so a knob
// move is recorded as automation exactly like the host's own. Gestures bracket a drag so
// the host sees one edit rather than a few hundred unrelated values.
//
// Only the GUI thread touches `write`; only the audio thread touches `read`. Neither ever
// blocks: if the queue is full the edit is dropped, which is the right trade for a control
// surface — the next mouse-move is a fresher value anyway.

UI_QUEUE_CAPACITY :: 512 // power of two, so the mask is a bitwise and

Ui_Event_Kind :: enum u8 {
	Gesture_Begin,
	Value,
	Gesture_End,
}

Ui_Event :: struct {
	kind:  Ui_Event_Kind,
	param: clap.Clap_Id,
	value: f64,
}

Ui_Queue :: struct {
	items: [UI_QUEUE_CAPACITY]Ui_Event,
	write: u32,
	read:  u32,
}

// [gui-thread]
ui_queue_push :: proc "contextless" (queue: ^Ui_Queue, event: Ui_Event) -> bool {
	write := intrinsics.atomic_load_explicit(&queue.write, .Relaxed)
	read := intrinsics.atomic_load_explicit(&queue.read, .Acquire)

	if write - read >= UI_QUEUE_CAPACITY {
		return false // full
	}

	queue.items[write & (UI_QUEUE_CAPACITY - 1)] = event
	// Release so the item write above is visible before the index that publishes it.
	intrinsics.atomic_store_explicit(&queue.write, write + 1, .Release)
	return true
}

// [audio-thread]
ui_queue_pop :: proc "contextless" (queue: ^Ui_Queue) -> (event: Ui_Event, ok: bool) {
	read := intrinsics.atomic_load_explicit(&queue.read, .Relaxed)
	write := intrinsics.atomic_load_explicit(&queue.write, .Acquire)

	if read == write {
		return {}, false
	}

	event = queue.items[read & (UI_QUEUE_CAPACITY - 1)]
	intrinsics.atomic_store_explicit(&queue.read, read + 1, .Release)
	return event, true
}

//
// Values published back to the GUI
//
// The audio thread owns `values`; the GUI reads a mirror of it. f64 has no atomic
// intrinsic, so the bits travel as u64 — which is exact, since this is a copy rather than
// arithmetic.

publish :: proc "contextless" (slot: ^u64, value: f64) {
	intrinsics.atomic_store_explicit(slot, transmute(u64)value, .Relaxed)
}

read_published :: proc "contextless" (slot: ^u64) -> f64 {
	return transmute(f64)intrinsics.atomic_load_explicit(slot, .Relaxed)
}
