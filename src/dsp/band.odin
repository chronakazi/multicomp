package dsp

// One band of compression: detector -> static curve -> envelope -> gain.
//
// This is the multiband seam. The plugin holds `bands: []Compressor_Band` with a single
// entry today; going multiband means adding a crossover and growing that slice, while the
// per-band DSP below stays exactly as it is.

Topology_Mode :: enum {
	// The detector sees the input. Predictable, and what most modern compressors do.
	Feed_Forward,
	// The detector sees the output. The effective ratio becomes level-dependent and the
	// knee softens on its own, which is a large part of why older hardware designs
	// behave the way they do.
	Feedback,
}

Compressor_Band :: struct {
	detector: Level_Detector,
	computer: Gain_Computer,
	envelope: Envelope_Follower,
	topology: Topology_Mode,

	// Gain applied on the previous sample, in dB. Only used by the feedback topology,
	// where it closes the loop.
	last_gain_db: f64,
}

band_init :: proc "contextless" (band: ^Compressor_Band, sample_rate: f64) {
	level_detector_init(&band.detector, .Peak, sample_rate)
	envelope_set_times(&band.envelope, 10, 100, sample_rate)
	gain_computer_set(&band.computer, -18, 4, 6)
	band.topology = .Feed_Forward
	band_reset(band)
}

band_reset :: proc "contextless" (band: ^Compressor_Band) {
	level_detector_reset(&band.detector)
	envelope_reset(&band.envelope)
	band.last_gain_db = 0
}

// Advances the band by one sample and returns the gain to apply, in dB (<= 0).
//
// `detector_input` is the already-conditioned signal feeding the detector: sidechain
// filtered and stereo-linked by the caller. Keeping that outside the band is what lets
// several bands share one detector source later.
band_tick :: proc "contextless" (band: ^Compressor_Band, detector_input: f64) -> f64 {
	sense := detector_input
	if band.topology == .Feedback {
		// Close the loop with the gain we applied last sample.
		sense *= db_to_linear(band.last_gain_db)
	}

	level_db := level_detector_tick(&band.detector, sense)
	wanted_reduction := gain_computer_reduction_db(band.computer, level_db)
	smoothed_reduction := envelope_tick(&band.envelope, wanted_reduction)

	band.last_gain_db = -smoothed_reduction
	return band.last_gain_db
}
