package dsp

// One band of compression: detector -> static curve -> envelope -> gain, per channel.
//
// This is the multiband seam. The plugin holds several of these with a single entry today;
// going multiband means adding a crossover and growing that array, while the per-band DSP
// below stays exactly as it is.

MAX_CHANNELS :: 2

Topology_Mode :: enum {
	// The detector sees the input. Predictable, and what most modern compressors do.
	Feed_Forward,
	// The detector sees the output. The effective ratio becomes level-dependent and the
	// knee softens on its own, which is a large part of why older hardware designs
	// behave the way they do.
	Feedback,
}

// Per-channel detection state. Each channel gets its own detector and envelope so the
// band can run them independently when stereo link is below 100%.
Band_Channel :: struct {
	detector:     Level_Detector,
	envelope:     Envelope_Follower,
	last_gain_db: f64,
}

Compressor_Band :: struct {
	computer:      Gain_Computer,
	topology:      Topology_Mode,

	// 0 = every channel compresses on its own level, 1 = every channel follows the
	// loudest. Anything in between blends the two, in dB.
	stereo_link:   f64,
	channels:      [MAX_CHANNELS]Band_Channel,
	channel_count: int,
}

band_init :: proc "contextless" (band: ^Compressor_Band, sample_rate: f64, channel_count := 2) {
	band.channel_count = clamp(channel_count, 1, MAX_CHANNELS)
	band.topology = .Feed_Forward
	band.stereo_link = 1
	gain_computer_set(&band.computer, -18, 1, 6)

	for index in 0 ..< band.channel_count {
		channel := &band.channels[index]
		level_detector_init(&channel.detector, .Peak, sample_rate)
		envelope_set_times(&channel.envelope, 10, 100, sample_rate)
	}
	band_reset(band)
}

band_reset :: proc "contextless" (band: ^Compressor_Band) {
	for index in 0 ..< MAX_CHANNELS {
		channel := &band.channels[index]
		level_detector_reset(&channel.detector)
		envelope_reset(&channel.envelope)
		channel.last_gain_db = 0
	}
}

band_set_detector :: proc "contextless" (band: ^Compressor_Band, mode: Detector_Mode) {
	for index in 0 ..< MAX_CHANNELS {
		band.channels[index].detector.mode = mode
	}
}

band_set_times :: proc "contextless" (
	band: ^Compressor_Band,
	attack_ms, release_ms, sample_rate: f64,
	auto_release := false,
) {
	for index in 0 ..< MAX_CHANNELS {
		envelope := &band.channels[index].envelope
		envelope_set_times(envelope, attack_ms, release_ms, sample_rate)
		envelope.auto_release = auto_release
	}
}

// Advances the band by one sample.
//
// `inputs` are the already-conditioned detector sources for each channel - trimmed,
// sidechain-filtered and mid/side encoded by the caller. Keeping that conditioning outside
// the band is what will let several bands share one detector source later.
//
// `gains_db` receives the gain to apply to each channel, in dB (<= 0).
band_tick :: proc "contextless" (band: ^Compressor_Band, inputs, gains_db: []f64) {
	count := min(len(inputs), len(gains_db), band.channel_count)

	levels: [MAX_CHANNELS]f64
	loudest := SILENCE_DB

	for index in 0 ..< count {
		channel := &band.channels[index]

		sense := inputs[index]
		if band.topology == .Feedback {
			// Close the loop with the gain we applied last sample.
			sense *= db_to_linear(channel.last_gain_db)
		}

		levels[index] = level_detector_tick(&channel.detector, sense)
		loudest = max(loudest, levels[index])
	}

	for index in 0 ..< count {
		channel := &band.channels[index]

		// Blend this channel's own level toward the loudest one. At full link every
		// channel sees the same level and therefore the same gain, which is what keeps
		// the stereo image from being pulled around on transients.
		level := levels[index] + (loudest - levels[index]) * band.stereo_link

		reduction := gain_computer_reduction_db(band.computer, level)
		smoothed := envelope_tick(&channel.envelope, reduction)

		channel.last_gain_db = -smoothed
		gains_db[index] = channel.last_gain_db
	}
}
