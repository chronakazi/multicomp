package dsp

import "core:math"

// Biquad filter, transposed direct form II.
//
// Coefficients follow the Audio EQ Cookbook (Robert Bristow-Johnson). Used for the
// sidechain high-pass now; the Linkwitz-Riley crossovers for multiband are cascaded
// Butterworth sections built from the same primitive.

// Butterworth Q for a single second-order section: 1/sqrt(2).
BUTTERWORTH_Q :: 0.70710678118654752

Biquad :: struct {
	b0, b1, b2: f64,
	a1, a2:     f64,
	s1, s2:     f64, // state
}

biquad_reset :: proc "contextless" (filter: ^Biquad) {
	filter.s1 = 0
	filter.s2 = 0
}

biquad_set_highpass :: proc "contextless" (
	filter: ^Biquad,
	frequency, q, sample_rate: f64,
) {
	// Keep the corner below Nyquist; a frequency at or above it has no meaningful
	// bilinear-transform mapping and would produce garbage coefficients.
	f := clamp(frequency, 1, sample_rate * 0.49)
	w0 := 2 * math.PI * f / sample_rate
	cos_w0 := math.cos(w0)
	alpha := math.sin(w0) / (2 * max(q, 0.001))

	a0 := 1 + alpha
	filter.b0 = ((1 + cos_w0) / 2) / a0
	filter.b1 = (-(1 + cos_w0)) / a0
	filter.b2 = ((1 + cos_w0) / 2) / a0
	filter.a1 = (-2 * cos_w0) / a0
	filter.a2 = (1 - alpha) / a0
}

biquad_set_lowpass :: proc "contextless" (filter: ^Biquad, frequency, q, sample_rate: f64) {
	f := clamp(frequency, 1, sample_rate * 0.49)
	w0 := 2 * math.PI * f / sample_rate
	cos_w0 := math.cos(w0)
	alpha := math.sin(w0) / (2 * max(q, 0.001))

	a0 := 1 + alpha
	filter.b0 = ((1 - cos_w0) / 2) / a0
	filter.b1 = (1 - cos_w0) / a0
	filter.b2 = ((1 - cos_w0) / 2) / a0
	filter.a1 = (-2 * cos_w0) / a0
	filter.a2 = (1 - alpha) / a0
}

// Configure as a pass-through, for when the sidechain filter is effectively off.
biquad_set_bypass :: proc "contextless" (filter: ^Biquad) {
	filter.b0 = 1
	filter.b1 = 0
	filter.b2 = 0
	filter.a1 = 0
	filter.a2 = 0
}

biquad_tick :: proc "contextless" (filter: ^Biquad, sample: f64) -> f64 {
	out := filter.b0 * sample + filter.s1
	filter.s1 = filter.b1 * sample - filter.a1 * out + filter.s2
	filter.s2 = filter.b2 * sample - filter.a2 * out
	return out
}
