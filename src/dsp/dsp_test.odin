package dsp

import "core:math"
import "core:testing"

// Run with:  odin test src/dsp

SR :: 48000.0

expect_near :: proc(
	t: ^testing.T,
	actual, expected, tolerance: f64,
	what: string,
	loc := #caller_location,
) {
	delta := abs(actual - expected)
	testing.expectf(
		t,
		delta <= tolerance,
		"%s: got %.6f, expected %.6f (+/- %.6f), off by %.6f",
		what,
		actual,
		expected,
		tolerance,
		delta,
		loc = loc,
	)
}

//
// Static curve
//

@(test)
gain_computer_hard_knee :: proc(t: ^testing.T) {
	computer: Gain_Computer
	gain_computer_set(&computer, -20, 4, 0)

	// Well below threshold: untouched.
	expect_near(t, gain_computer_output_db(computer, -40), -40, 1e-9, "below threshold")
	expect_near(t, gain_computer_reduction_db(computer, -40), 0, 1e-9, "reduction below threshold")

	// Exactly at threshold: still untouched.
	expect_near(t, gain_computer_output_db(computer, -20), -20, 1e-9, "at threshold")

	// 12 dB over at 4:1 -> 3 dB over, so 9 dB of reduction.
	expect_near(t, gain_computer_output_db(computer, -8), -17, 1e-9, "12 dB over at 4:1")
	expect_near(t, gain_computer_reduction_db(computer, -8), 9, 1e-9, "reduction 12 dB over")
}

@(test)
gain_computer_ratios :: proc(t: ^testing.T) {
	computer: Gain_Computer

	// 1:1 is a no-op at any level.
	gain_computer_set(&computer, -20, 1, 0)
	expect_near(t, gain_computer_output_db(computer, 0), 0, 1e-9, "1:1 passes through")

	// 2:1, 20 dB over -> 10 dB over.
	gain_computer_set(&computer, -20, 2, 0)
	expect_near(t, gain_computer_output_db(computer, 0), -10, 1e-9, "2:1")

	// Infinite ratio holds everything at threshold.
	gain_computer_set_limiting(&computer, -20, 0)
	expect_near(t, gain_computer_output_db(computer, 0), -20, 1e-9, "limiting at 0 dB")
	expect_near(t, gain_computer_output_db(computer, -5), -20, 1e-9, "limiting at -5 dB")
	expect_near(t, gain_computer_output_db(computer, -30), -30, 1e-9, "limiting below threshold")
}

@(test)
gain_computer_knee_is_continuous :: proc(t: ^testing.T) {
	computer: Gain_Computer
	threshold := -20.0
	knee := 12.0
	gain_computer_set(&computer, threshold, 4, knee)

	lower := threshold - knee / 2
	upper := threshold + knee / 2

	// At the knee edges the curve must agree with the straight segments it joins.
	expect_near(t, gain_computer_output_db(computer, lower), lower, 1e-9, "lower knee edge")
	expect_near(
		t,
		gain_computer_output_db(computer, upper),
		threshold + (upper - threshold) / 4,
		1e-9,
		"upper knee edge",
	)

	// And it must not jump anywhere across the knee.
	previous := gain_computer_output_db(computer, lower - 1)
	for i in 0 ..= 200 {
		level := lower - 1 + f64(i) * (knee + 2) / 200
		current := gain_computer_output_db(computer, level)
		testing.expectf(
			t,
			current-previous >= -1e-9,
			"curve must be monotonic, went from %.6f to %.6f at %.3f dB",
			previous,
			current,
			level,
		)
		testing.expectf(
			t,
			abs(current - previous) < 0.5,
			"curve jumped %.6f dB at %.3f dB in",
			current - previous,
			level,
		)
		previous = current
	}

	hard: Gain_Computer
	gain_computer_set(&hard, threshold, 4, 0)

	// The soft knee starts working below the threshold, where a hard knee is still
	// untouched. This is the whole point of a knee, and it means that *inside* the knee
	// the soft curve has applied more cumulative reduction, not less - the two converge
	// only at the upper knee edge. (Slope is gentler; total reduction is not.)
	expect_near(
		t,
		gain_computer_reduction_db(hard, threshold - knee / 4),
		0,
		1e-9,
		"hard knee is inactive below threshold",
	)
	testing.expect(
		t,
		gain_computer_reduction_db(computer, threshold - knee / 4) > 0,
		"soft knee should already be reducing below threshold",
	)

	// Above the knee the two are identical again.
	for level in ([?]f64{upper, upper + 6, upper + 20}) {
		expect_near(
			t,
			gain_computer_output_db(computer, level),
			gain_computer_output_db(hard, level),
			1e-9,
			"soft and hard agree above the knee",
		)
	}

	// The local slope must sweep smoothly from 1 to 1/ratio across the knee.
	slope_at :: proc(computer: Gain_Computer, level: f64) -> f64 {
		h := 1e-6
		return(
			(gain_computer_output_db(computer, level + h) -
				gain_computer_output_db(computer, level - h)) /
			(2 * h) \
		)
	}
	expect_near(t, slope_at(computer, lower + 1e-3), 1, 1e-3, "slope is 1 at the lower edge")
	expect_near(t, slope_at(computer, upper - 1e-3), 0.25, 1e-3, "slope is 1/ratio at the upper edge")
	expect_near(t, slope_at(computer, threshold), 0.625, 1e-3, "slope is halfway at the threshold")
}

//
// Envelope timing
//

// Drives the follower with a constant reduction and returns how many samples it takes to
// cross 63.2% of it - the definition of the time constant used by one_pole_coeff.
samples_to_632 :: proc(envelope: ^Envelope_Follower, target: f64, limit: int) -> int {
	goal := target * (1 - 1 / math.E)
	for i in 0 ..< limit {
		if envelope_tick(envelope, target) >= goal {
			return i + 1
		}
	}
	return limit
}

@(test)
envelope_attack_time :: proc(t: ^testing.T) {
	for attack_ms in ([?]f64{1, 10, 50}) {
		envelope: Envelope_Follower
		envelope_set_times(&envelope, attack_ms, 100, SR)
		envelope_reset(&envelope)

		got := samples_to_632(&envelope, 12, int(SR))
		expected := attack_ms / 1000 * SR

		// Within 5%: the decoupled topology adds a little lag over a bare one-pole.
		expect_near(
			t,
			f64(got),
			expected,
			expected * 0.05 + 1,
			"attack samples to 63.2% at 1 ms scale",
		)
	}
}

@(test)
envelope_release_time :: proc(t: ^testing.T) {
	release_ms := 100.0
	envelope: Envelope_Follower
	envelope_set_times(&envelope, 0.01, release_ms, SR)
	envelope_reset(&envelope)

	// Drive it to a steady 12 dB of reduction.
	for _ in 0 ..< int(SR) {
		envelope_tick(&envelope, 12)
	}
	start := envelope.output
	expect_near(t, start, 12, 0.1, "envelope should reach the driven level")

	// Release to zero and time the decay to 1/e of the starting value.
	goal := start / math.E
	samples := 0
	for i in 0 ..< int(SR) {
		if envelope_tick(&envelope, 0) <= goal {
			samples = i + 1
			break
		}
	}
	expected := release_ms / 1000 * SR
	expect_near(t, f64(samples), expected, expected*0.05 + 1, "release samples to 1/e")
}

@(test)
envelope_never_goes_negative :: proc(t: ^testing.T) {
	envelope: Envelope_Follower
	envelope_set_times(&envelope, 5, 50, SR)
	envelope_reset(&envelope)

	for i in 0 ..< 10000 {
		reduction := i % 100 < 50 ? 9.0 : 0.0
		out := envelope_tick(&envelope, reduction)
		testing.expectf(t, out >= -1e-12, "envelope output went negative: %.9f", out)
		testing.expectf(t, out <= 9.0 + 1e-9, "envelope overshot the input: %.9f", out)
	}
}

//
// Detectors
//

@(test)
rms_detector_converges_on_sine :: proc(t: ^testing.T) {
	detector: Level_Detector
	level_detector_init(&detector, .RMS, SR)
	level_detector_reset(&detector)

	amplitude := 0.5
	frequency := 1000.0
	last := 0.0

	// A full second is many RMS windows, so it should be well settled.
	for i in 0 ..< int(SR) {
		phase := 2 * math.PI * frequency * f64(i) / SR
		last = level_detector_tick(&detector, amplitude * math.sin(phase))
	}

	// RMS of a sine is amplitude / sqrt(2).
	expected := linear_to_db(amplitude / math.SQRT_TWO)
	expect_near(t, last, expected, 0.5, "RMS of a 0.5 sine")
}

@(test)
peak_detector_tracks_amplitude :: proc(t: ^testing.T) {
	detector: Level_Detector
	level_detector_init(&detector, .Peak, SR)

	expect_near(t, level_detector_tick(&detector, 1.0), 0, 1e-9, "peak of 1.0 is 0 dB")
	expect_near(t, level_detector_tick(&detector, -1.0), 0, 1e-9, "peak is magnitude")
	expect_near(t, level_detector_tick(&detector, 0.5), -6.0206, 1e-3, "peak of 0.5")
	expect_near(t, level_detector_tick(&detector, 0), SILENCE_DB, 1e-9, "silence floors out")
}

@(test)
hybrid_detector_is_at_least_rms :: proc(t: ^testing.T) {
	hybrid, rms: Level_Detector
	level_detector_init(&hybrid, .Hybrid, SR)
	level_detector_init(&rms, .RMS, SR)

	for i in 0 ..< 4800 {
		phase := 2 * math.PI * 220 * f64(i) / SR
		sample := 0.7 * math.sin(phase)
		h := level_detector_tick(&hybrid, sample)
		r := level_detector_tick(&rms, sample)
		testing.expectf(t, h >= r-1e-9, "hybrid %.6f fell below rms %.6f", h, r)
	}
}

//
// Primitives
//

@(test)
delay_line_delays_exactly :: proc(t: ^testing.T) {
	storage: [64]f64
	line: Delay_Line
	delay_line_init(&line, storage[:])
	delay_line_set_delay(&line, 5)

	// The first 5 outputs are the zero-filled buffer, then the input reappears.
	for i in 0 ..< 40 {
		out := delay_line_tick(&line, f64(i + 1))
		expected := i < 5 ? 0 : f64(i - 5 + 1)
		expect_near(t, out, expected, 1e-12, "delayed sample")
	}
}

@(test)
delay_line_zero_delay_is_passthrough :: proc(t: ^testing.T) {
	storage: [16]f64
	line: Delay_Line
	delay_line_init(&line, storage[:])
	delay_line_set_delay(&line, 0)

	for i in 0 ..< 32 {
		expect_near(t, delay_line_tick(&line, f64(i)), f64(i), 1e-12, "passthrough")
	}
}

@(test)
delay_line_clamps_oversized_delay :: proc(t: ^testing.T) {
	storage: [8]f64
	line: Delay_Line
	delay_line_init(&line, storage[:])
	delay_line_set_delay(&line, 1000)
	testing.expect_value(t, line.delay, 7)
}

@(test)
biquad_highpass_response :: proc(t: ^testing.T) {
	filter: Biquad
	biquad_set_highpass(&filter, 100, BUTTERWORTH_Q, SR)

	// DC must be rejected.
	biquad_reset(&filter)
	dc := 0.0
	for _ in 0 ..< 2000 {
		dc = biquad_tick(&filter, 1.0)
	}
	expect_near(t, dc, 0, 1e-3, "high-pass rejects DC")

	// Well above the corner it should pass at close to unity.
	expect_near(t, measure_gain(&filter, 5000, SR), 1.0, 0.05, "gain at 5 kHz")

	// At the corner a Butterworth section is -3 dB, i.e. about 0.707.
	expect_near(t, measure_gain(&filter, 100, SR), math.SQRT_TWO / 2, 0.05, "gain at corner")

	// An octave below the corner, a 2nd-order high-pass is about -12 dB.
	expect_near(t, measure_gain(&filter, 50, SR), db_to_linear(-12), 0.03, "gain an octave down")
}

// Peak amplitude of a settled sine through the filter.
measure_gain :: proc(filter: ^Biquad, frequency, sample_rate: f64) -> f64 {
	biquad_reset(filter)
	peak := 0.0
	cycles := 200
	total := int(sample_rate / frequency * f64(cycles))
	settle := total / 2

	for i in 0 ..< total {
		phase := 2 * math.PI * frequency * f64(i) / sample_rate
		out := biquad_tick(filter, math.sin(phase))
		if i >= settle {
			peak = max(peak, abs(out))
		}
	}
	return peak
}

@(test)
biquad_bypass_is_exact :: proc(t: ^testing.T) {
	filter: Biquad
	biquad_set_bypass(&filter)
	for i in 0 ..< 100 {
		value := math.sin(f64(i))
		expect_near(t, biquad_tick(&filter, value), value, 1e-15, "bypass passes through")
	}
}

@(test)
smoother_converges_to_target :: proc(t: ^testing.T) {
	smoother: Smoother
	smoother_init(&smoother, 10, SR, 0)
	smoother_set_target(&smoother, 1)

	// One time constant should land near 63.2%.
	for _ in 0 ..< int(10.0 / 1000 * SR) {
		smoother_tick(&smoother)
	}
	expect_near(t, smoother.value, 1-1/math.E, 0.01, "smoother after one time constant")

	// And it must actually arrive.
	for _ in 0 ..< int(SR) {
		smoother_tick(&smoother)
	}
	expect_near(t, smoother.value, 1, 1e-6, "smoother settles")
	testing.expect(t, smoother_is_settled(smoother), "smoother reports settled")
}

@(test)
smoother_snap_skips_the_ramp :: proc(t: ^testing.T) {
	smoother: Smoother
	smoother_init(&smoother, 50, SR, 0)
	smoother_snap(&smoother, 0.75)
	expect_near(t, smoother.value, 0.75, 1e-12, "snap sets value immediately")
	expect_near(t, smoother_tick(&smoother), 0.75, 1e-12, "and stays there")
}

//
// Band integration
//

// Convenience for the single-channel cases below.
band_tick_mono :: proc(band: ^Compressor_Band, sample: f64) -> f64 {
	inputs := [1]f64{sample}
	gains: [1]f64
	band_tick(band, inputs[:], gains[:])
	return gains[0]
}

@(test)
band_compresses_steady_tone :: proc(t: ^testing.T) {
	band: Compressor_Band
	band_init(&band, SR, 1)
	gain_computer_set(&band.computer, -20, 4, 0)
	band_set_times(&band, 1, 10, SR)
	band_set_detector(&band, .Peak)
	band_reset(&band)

	// A steady -8 dBFS tone is 12 dB over threshold; at 4:1 that is 9 dB of reduction.
	amplitude := db_to_linear(-8)
	gain_db := 0.0
	for i in 0 ..< int(SR) {
		phase := 2 * math.PI * 1000 * f64(i) / SR
		gain_db = band_tick_mono(&band, amplitude * math.sin(phase))
	}

	// Peak detection on a sine ripples with the waveform, so this is a loose bound.
	testing.expectf(
		t,
		gain_db < -6 && gain_db > -11,
		"expected roughly -9 dB of gain, got %.3f dB",
		gain_db,
	)
}

@(test)
band_leaves_quiet_signal_alone :: proc(t: ^testing.T) {
	band: Compressor_Band
	band_init(&band, SR, 1)
	gain_computer_set(&band.computer, -20, 4, 0)
	band_reset(&band)

	amplitude := db_to_linear(-40)
	for i in 0 ..< 4800 {
		phase := 2 * math.PI * 1000 * f64(i) / SR
		gain_db := band_tick_mono(&band, amplitude * math.sin(phase))
		expect_near(t, gain_db, 0, 1e-9, "no reduction below threshold")
	}
}

@(test)
band_unity_ratio_is_exactly_transparent :: proc(t: ^testing.T) {
	// The plugin relies on this: ratio 1:1 must produce a gain of exactly 0 dB at every
	// level, whatever the threshold and knee are, so a freshly inserted plugin is
	// bit-transparent.
	band: Compressor_Band
	band_init(&band, SR, 2)
	gain_computer_set(&band.computer, -40, 1, 12)
	band_reset(&band)

	inputs, gains: [2]f64
	for i in 0 ..< 4800 {
		phase := 2 * math.PI * 1000 * f64(i) / SR
		inputs[0] = math.sin(phase)
		inputs[1] = 0.5 * math.sin(phase)
		band_tick(&band, inputs[:], gains[:])
		expect_near(t, gains[0], 0, 0, "left gain is exactly unity")
		expect_near(t, gains[1], 0, 0, "right gain is exactly unity")
	}
}

@(test)
band_feedback_reduces_less_than_feedforward :: proc(t: ^testing.T) {
	// With the detector fed from the output, the loop settles at less reduction than the
	// feed-forward case for the same input. That is the defining behaviour of the topology.
	run :: proc(topology: Topology_Mode) -> f64 {
		band: Compressor_Band
		band_init(&band, SR, 1)
		gain_computer_set(&band.computer, -20, 4, 0)
		band_set_times(&band, 1, 10, SR)
		band.topology = topology
		band_reset(&band)

		amplitude := db_to_linear(-8)
		gain_db := 0.0
		for i in 0 ..< int(SR) {
			phase := 2 * math.PI * 1000 * f64(i) / SR
			gain_db = band_tick_mono(&band, amplitude * math.sin(phase))
		}
		return gain_db
	}

	feed_forward := run(.Feed_Forward)
	feedback := run(.Feedback)

	testing.expectf(
		t,
		feedback > feed_forward,
		"feedback (%.3f dB) should reduce less than feed-forward (%.3f dB)",
		feedback,
		feed_forward,
	)
}

//
// Stereo link
//

// Drives one loud channel and one quiet one, and reports the settled gain of each.
//
// The quiet level matters: the blended level has to land above the threshold for the link
// amount to show up at all. Blending -40 dBFS halfway toward -8 gives -24, still under a
// -20 threshold, so a half-linked channel would correctly show no reduction whatsoever.
run_asymmetric :: proc(link: f64, quiet_db := -40.0) -> (loud, quiet: f64) {
	band: Compressor_Band
	band_init(&band, SR, 2)
	gain_computer_set(&band.computer, -20, 4, 0)
	band_set_times(&band, 1, 10, SR)
	band.stereo_link = link
	band_reset(&band)

	inputs, gains: [2]f64
	for i in 0 ..< int(SR) {
		phase := 2 * math.PI * 1000 * f64(i) / SR
		inputs[0] = db_to_linear(-8) * math.sin(phase)
		inputs[1] = db_to_linear(quiet_db) * math.sin(phase)
		band_tick(&band, inputs[:], gains[:])
	}
	return gains[0], gains[1]
}

@(test)
stereo_link_full_moves_both_channels_together :: proc(t: ^testing.T) {
	loud, quiet := run_asymmetric(1)
	expect_near(t, quiet, loud, 1e-9, "fully linked channels must share one gain")
	testing.expectf(t, loud < -6, "loud channel should still be compressed, got %.3f", loud)
}

@(test)
stereo_link_zero_leaves_channels_independent :: proc(t: ^testing.T) {
	loud, quiet := run_asymmetric(0)
	testing.expectf(t, loud < -6, "loud channel should be compressed, got %.3f dB", loud)
	expect_near(t, quiet, 0, 1e-9, "quiet channel is below threshold and must be untouched")
}

@(test)
stereo_link_half_is_between :: proc(t: ^testing.T) {
	// -26 dBFS blended halfway toward -8 lands at -17, comfortably over the threshold.
	QUIET :: -26.0
	_, quiet_linked := run_asymmetric(1, QUIET)
	_, quiet_free := run_asymmetric(0, QUIET)
	_, quiet_half := run_asymmetric(0.5, QUIET)

	testing.expectf(
		t,
		quiet_half < quiet_free - 1e-6 && quiet_half > quiet_linked + 1e-6,
		"50%% link (%.3f dB) should sit between free (%.3f) and linked (%.3f)",
		quiet_half,
		quiet_free,
		quiet_linked,
	)
}

//
// Auto release
//

@(test)
auto_release_recovers_faster_after_a_brief_peak :: proc(t: ^testing.T) {
	// Same nominal release time; the auto version should return to unity sooner after a
	// shallow, short-lived reduction.
	settle :: proc(auto: bool) -> int {
		envelope: Envelope_Follower
		envelope_set_times(&envelope, 0.1, 200, SR)
		envelope.auto_release = auto
		envelope_reset(&envelope)

		// A brief 3 dB dip.
		for _ in 0 ..< int(SR / 100) {
			envelope_tick(&envelope, 3)
		}
		for i in 0 ..< int(SR) {
			if envelope_tick(&envelope, 0) < 0.1 {
				return i
			}
		}
		return int(SR)
	}

	fast := settle(true)
	slow := settle(false)
	testing.expectf(
		t,
		fast < slow,
		"auto release should recover sooner: auto %d samples vs fixed %d",
		fast,
		slow,
	)
}

@(test)
auto_release_off_is_unchanged :: proc(t: ^testing.T) {
	// The flag must be inert when off, so existing behaviour is untouched.
	a, b: Envelope_Follower
	envelope_set_times(&a, 5, 120, SR)
	envelope_set_times(&b, 5, 120, SR)
	a.auto_release = false
	b.auto_release = false

	for i in 0 ..< 5000 {
		reduction := i % 200 < 100 ? 8.0 : 0.0
		expect_near(t, envelope_tick(&a, reduction), envelope_tick(&b, reduction), 0, "identical")
	}
}

//
// Mid-side
//

@(test)
mid_side_round_trips_exactly :: proc(t: ^testing.T) {
	for i in 0 ..< 1000 {
		left := math.sin(f64(i) * 0.1)
		right := math.cos(f64(i) * 0.07) * 0.3

		mid, side := encode_mid_side(left, right)
		back_left, back_right := decode_mid_side(mid, side)

		expect_near(t, back_left, left, 1e-15, "left survives the round trip")
		expect_near(t, back_right, right, 1e-15, "right survives the round trip")
	}
}

@(test)
mid_side_separates_centre_from_width :: proc(t: ^testing.T) {
	// A mono signal is all mid, no side.
	mid, side := encode_mid_side(0.7, 0.7)
	expect_near(t, mid, 0.7, 1e-15, "mono is all mid")
	expect_near(t, side, 0, 1e-15, "mono has no side")

	// A perfectly out-of-phase signal is all side, no mid.
	mid, side = encode_mid_side(0.7, -0.7)
	expect_near(t, mid, 0, 1e-15, "out of phase has no mid")
	expect_near(t, side, 0.7, 1e-15, "out of phase is all side")
}
