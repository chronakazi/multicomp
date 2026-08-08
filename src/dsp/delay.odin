package dsp

// Fixed-delay circular buffer, used for the lookahead path.
//
// The backing storage is supplied by the caller rather than allocated here, so this
// package stays allocation-free. The plugin allocates it in `activate`, which is the
// main thread and where CLAP explicitly permits allocation.

Delay_Line :: struct {
	buffer: []f64,
	write:  int,
	delay:  int,
}

delay_line_init :: proc "contextless" (line: ^Delay_Line, buffer: []f64) {
	line.buffer = buffer
	line.write = 0
	line.delay = 0
	delay_line_clear(line)
}

delay_line_clear :: proc "contextless" (line: ^Delay_Line) {
	for &sample in line.buffer {
		sample = 0
	}
	line.write = 0
}

// Clamped to the buffer that was handed in, so an over-long lookahead degrades to the
// maximum available delay instead of reading out of bounds.
delay_line_set_delay :: proc "contextless" (line: ^Delay_Line, samples: int) {
	if len(line.buffer) == 0 {
		line.delay = 0
		return
	}
	line.delay = clamp(samples, 0, len(line.buffer) - 1)
}

delay_line_tick :: proc "contextless" (line: ^Delay_Line, sample: f64) -> f64 {
	if len(line.buffer) == 0 {
		return sample
	}

	line.buffer[line.write] = sample

	// Read after writing, so a delay of 0 correctly returns the current sample.
	read := line.write - line.delay
	if read < 0 {
		read += len(line.buffer)
	}
	out := line.buffer[read]

	line.write += 1
	if line.write >= len(line.buffer) {
		line.write = 0
	}
	return out
}
