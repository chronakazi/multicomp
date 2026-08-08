package dsp

// One-pole parameter smoother.
//
// Continuous parameters are smoothed before they reach the DSP so that a knob move, or a
// coarse automation curve from the host, does not step the gain discontinuously and
// produce zipper noise.

Smoother :: struct {
	coeff:  f64,
	value:  f64,
	target: f64,
}

smoother_init :: proc "contextless" (
	smoother: ^Smoother,
	time_ms, sample_rate: f64,
	initial: f64 = 0,
) {
	smoother.coeff = one_pole_coeff(time_ms / 1000, sample_rate)
	smoother.value = initial
	smoother.target = initial
}

// Jump straight to a value, skipping the ramp. Used when the plugin resets, so the
// first block after a transport locate does not ramp up from stale state.
smoother_snap :: proc "contextless" (smoother: ^Smoother, value: f64) {
	smoother.value = value
	smoother.target = value
}

smoother_set_target :: proc "contextless" (smoother: ^Smoother, target: f64) {
	smoother.target = target
}

smoother_tick :: proc "contextless" (smoother: ^Smoother) -> f64 {
	smoother.value = smoother.coeff * smoother.value + (1 - smoother.coeff) * smoother.target
	return smoother.value
}

smoother_is_settled :: proc "contextless" (smoother: Smoother, epsilon: f64 = 1e-6) -> bool {
	return abs(smoother.target - smoother.value) <= epsilon
}
