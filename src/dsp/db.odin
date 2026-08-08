package dsp

import "core:math"

// Decibel conversions.
//
// Everything in this package is `proc "contextless"` so it stays callable from the
// CLAP audio callbacks, which are `proc "c"` and therefore have no Odin context.
// That restriction is deliberate: it makes an accidental allocation on the audio
// thread a compile error rather than a dropout.

// Anything quieter than this is treated as silence, so log10 never sees zero.
SILENCE_DB :: -120.0

db_to_linear :: proc "contextless" (db: f64) -> f64 {
	return math.pow(f64(10), db * 0.05)
}

linear_to_db :: proc "contextless" (linear: f64) -> f64 {
	if linear <= 0 {
		return SILENCE_DB
	}
	return max(SILENCE_DB, 20 * math.log10(linear))
}
