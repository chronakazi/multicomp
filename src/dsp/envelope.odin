package dsp

import "core:math"

// Level detection and envelope smoothing.

Detector_Mode :: enum {
	Peak,
	RMS,
	Hybrid,
}

// Averaging window for the RMS detector. Short enough to track syllables, long enough
// that it does not simply become a peak detector.
RMS_WINDOW_MS :: 10.0

Level_Detector :: struct {
	mode:      Detector_Mode,
	rms_coeff: f64,
	rms_state: f64, // running mean square
}

level_detector_init :: proc "contextless" (
	detector: ^Level_Detector,
	mode: Detector_Mode,
	sample_rate: f64,
) {
	detector.mode = mode
	detector.rms_coeff = one_pole_coeff(RMS_WINDOW_MS / 1000, sample_rate)
}

level_detector_reset :: proc "contextless" (detector: ^Level_Detector) {
	detector.rms_state = 0
}

// Returns the detected level in dB for one input sample.
//
// Hybrid takes whichever of the two reads higher: it behaves like RMS on sustained
// material but still sees transients the RMS average would smear over.
level_detector_tick :: proc "contextless" (detector: ^Level_Detector, sample: f64) -> f64 {
	peak := abs(sample)

	// The RMS state is advanced regardless of mode so switching detector mid-signal
	// does not start from a stale average.
	detector.rms_state =
		detector.rms_coeff * detector.rms_state + (1 - detector.rms_coeff) * sample * sample
	rms := math.sqrt(detector.rms_state)

	switch detector.mode {
	case .Peak:
		return linear_to_db(peak)
	case .RMS:
		return linear_to_db(rms)
	case .Hybrid:
		return linear_to_db(max(peak, rms))
	}
	return linear_to_db(peak)
}

// Smooth decoupled peak detector, from Giannoulis, Massberg & Reiss (JAES 2012), Fig. 7.
//
// A release-only stage feeds an attack/release stage. Compared with the naive branching
// design this removes the level-dependent attack time - the reason a compressor built the
// obvious way sounds wrong on transients - and it is what gives the smooth, program-like
// recovery you expect from an analogue-style unit.
//
// The signal being smoothed is the *gain reduction* in dB, always >= 0.
Envelope_Follower :: struct {
	attack_coeff:       f64,
	release_coeff:      f64,
	release_fast_coeff: f64,
	auto_release:       bool,
	stage1:             f64,
	output:             f64,
}

// Program-dependent release. With `auto_release` on, the release coefficient slides
// between a fast branch and the user's setting according to how deep the current gain
// reduction is: a brief transient recovers quickly, a sustained passage recovers at the
// full release time. This is the behaviour engineers describe as the compressor
// "breathing with the material" rather than pumping at one fixed rate.
AUTO_RELEASE_FAST_SCALE :: 0.25
AUTO_RELEASE_FULL_DB :: 12.0

envelope_set_times :: proc "contextless" (
	envelope: ^Envelope_Follower,
	attack_ms, release_ms, sample_rate: f64,
) {
	envelope.attack_coeff = one_pole_coeff(attack_ms / 1000, sample_rate)
	envelope.release_coeff = one_pole_coeff(release_ms / 1000, sample_rate)
	envelope.release_fast_coeff = one_pole_coeff(
		release_ms / 1000 * AUTO_RELEASE_FAST_SCALE,
		sample_rate,
	)
}

envelope_reset :: proc "contextless" (envelope: ^Envelope_Follower) {
	envelope.stage1 = 0
	envelope.output = 0
}

envelope_tick :: proc "contextless" (envelope: ^Envelope_Follower, reduction_db: f64) -> f64 {
	release := envelope.release_coeff
	if envelope.auto_release {
		// Blending the coefficients rather than the time constants is not strictly the
		// same curve, but it is monotonic, cheap, and avoids an exp() per sample.
		depth := clamp(envelope.output / AUTO_RELEASE_FULL_DB, 0, 1)
		release = envelope.release_fast_coeff +
			(envelope.release_coeff - envelope.release_fast_coeff) * depth
	}

	// Release-only stage: rises instantly, falls with the release coefficient.
	released := release * envelope.stage1 + (1 - release) * reduction_db
	envelope.stage1 = max(reduction_db, released)

	// Attack stage: a plain one-pole smoothing the result.
	envelope.output =
		envelope.attack_coeff * envelope.output + (1 - envelope.attack_coeff) * envelope.stage1
	return envelope.output
}
