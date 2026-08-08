package dsp

// The static compression curve, evaluated in the log domain.
//
// This is the quadratic soft-knee formulation from Giannoulis, Massberg & Reiss,
// "Digital Dynamic Range Compressor Design - A Tutorial and Analysis" (JAES 2012),
// section 2.1. The knee is a parabola joining the unity-slope segment below threshold
// to the compressed segment above it, chosen so the curve is continuous in both value
// and slope at the knee edges.

Gain_Computer :: struct {
	threshold_db: f64,
	// 1/ratio. Stored inverted so an infinite ratio (a limiter) is exactly 0 rather
	// than a division that has to be special-cased every sample.
	inv_ratio:    f64,
	knee_db:      f64,
}

gain_computer_set :: proc "contextless" (
	computer: ^Gain_Computer,
	threshold_db, ratio, knee_db: f64,
) {
	computer.threshold_db = threshold_db
	computer.inv_ratio = ratio > 0 ? 1 / ratio : 0
	computer.knee_db = max(0, knee_db)
}

// Set an infinite ratio directly, i.e. limiting: everything above threshold is held at
// threshold. The plugin layer maps the top of its ratio range to this.
gain_computer_set_limiting :: proc "contextless" (
	computer: ^Gain_Computer,
	threshold_db, knee_db: f64,
) {
	computer.threshold_db = threshold_db
	computer.inv_ratio = 0
	computer.knee_db = max(0, knee_db)
}

// Maps an input level in dB to an output level in dB.
gain_computer_output_db :: proc "contextless" (computer: Gain_Computer, input_db: f64) -> f64 {
	// A ratio of 1:1 is a no-op by definition, so say so exactly. Falling through would
	// compute `threshold + (input - threshold)`, which only equals `input` to within
	// floating point rounding - enough to leave a stray fraction of a dB of "reduction"
	// on a plugin that is supposed to be bit-transparent at its default settings.
	if computer.inv_ratio >= 1 {
		return input_db
	}

	over := input_db - computer.threshold_db
	knee := computer.knee_db

	// Below the knee: unity gain.
	if 2 * over < -knee {
		return input_db
	}

	// Inside the knee: quadratic interpolation between the two segments.
	if knee > 0 && 2 * abs(over) <= knee {
		delta := over + knee / 2
		return input_db + (computer.inv_ratio - 1) * delta * delta / (2 * knee)
	}

	// Above the knee: the compressed segment.
	return computer.threshold_db + over * computer.inv_ratio
}

// The gain reduction the curve asks for, as a positive number of dB.
// 0 means no reduction. This is the signal the envelope follower smooths.
gain_computer_reduction_db :: proc "contextless" (computer: Gain_Computer, input_db: f64) -> f64 {
	return input_db - gain_computer_output_db(computer, input_db)
}
