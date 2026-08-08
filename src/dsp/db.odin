package dsp

import "core:math"

// Everything in this package is `proc "contextless"` so it stays callable from the
// CLAP audio callbacks, which are `proc "c"` and therefore have no Odin context.
// That restriction is deliberate: it makes an accidental allocation on the audio
// thread a compile error rather than a dropout.
//
// This package must never import the CLAP bindings. Keeping it free of them is what
// lets the DSP be tested headlessly with `odin test`.

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

// One-pole smoothing coefficient for a given time constant.
//
// The convention here is the 1 - 1/e one: after `time_seconds` a step response has
// travelled 63.2% of the way. Some compressors quote 10%-90% instead, which is about
// 2.2x longer for the same filter — worth remembering when comparing attack times
// against another plugin's front panel.
//
// Returns 0 for a zero or negative time constant, meaning "instantaneous".
one_pole_coeff :: proc "contextless" (time_seconds, sample_rate: f64) -> f64 {
	if time_seconds <= 0 || sample_rate <= 0 {
		return 0
	}
	return math.exp(-1 / (time_seconds * sample_rate))
}
