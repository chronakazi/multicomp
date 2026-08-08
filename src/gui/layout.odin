package gui

// Where every control sits on the faceplate.
//
// The coordinates come straight from design/panel.html, which is authored at
// WIDTH x HEIGHT for exactly this reason. Bay widths there were computed from each knob's
// real footprint — 2*(r + TICK_REACH) — so nudging anything here by eye will reintroduce
// the tick-arc collisions that pass took out.

// CLAP parameter ids. These mirror Param_Id in plugin/params.odin; the two must agree,
// which `tools/guicheck` asserts by name so a reorder cannot go unnoticed.
P_BYPASS :: 0
P_INPUT_TRIM :: 1
P_THRESHOLD :: 2
P_RATIO :: 3
P_KNEE :: 4
P_ATTACK :: 5
P_RELEASE :: 6
P_AUTO_RELEASE :: 7
P_DETECTOR :: 8
P_TOPOLOGY :: 9
P_STEREO_LINK :: 10
P_CHANNEL_MODE :: 11
P_LOOKAHEAD :: 12
P_SC_SOURCE :: 13
P_SC_HIGHPASS :: 14
P_SC_LISTEN :: 15
P_MAKEUP :: 16
P_AUTO_MAKEUP :: 17
P_MIX :: 18
P_OUTPUT_TRIM :: 19

PARAM_COUNT :: 20

Control_Kind :: enum {
	Knob,
	Hero, // the Ratio knob: bigger cap, denser ticks, thicker pointer
	Button, // latching, with an indicator lamp
	Toggle, // two-position slide switch
	Selector, // rotary switch with labelled positions
}

Control :: struct {
	param:   u32,
	kind:    Control_Kind,
	x, y:    f32,
	r:       f32, // knobs and selectors
	label:   string,
	options: []string, // toggles and selectors
}

TOGGLE_W :: f32(17)
TOGGLE_H :: f32(40)
BUTTON_W :: f32(40)
BUTTON_H :: f32(24)

// Outermost tick radius past the cap. Bay widths were budgeted from this.
TICK_REACH :: f32(11)

CONTROLS := [?]Control {
	// INPUT
	{param = P_INPUT_TRIM, kind = .Knob, x = 79, y = 174, r = 26, label = "INPUT TRIM"},
	{param = P_BYPASS, kind = .Button, x = 79, y = 272, label = "BYPASS"},

	// COMPRESSOR
	{param = P_THRESHOLD, kind = .Knob, x = 181, y = 174, r = 26, label = "THRESHOLD"},
	{param = P_RATIO, kind = .Hero, x = 285, y = 178, r = 44, label = "RATIO"},
	{param = P_KNEE, kind = .Knob, x = 389, y = 174, r = 26, label = "KNEE"},

	// ENVELOPE
	{param = P_ATTACK, kind = .Knob, x = 490, y = 174, r = 26, label = "ATTACK"},
	{param = P_RELEASE, kind = .Knob, x = 576, y = 174, r = 26, label = "RELEASE"},
	{param = P_AUTO_RELEASE, kind = .Button, x = 533, y = 272, label = "AUTO RELEASE"},

	// OUTPUT
	{param = P_MAKEUP, kind = .Knob, x = 839, y = 174, r = 24, label = "MAKEUP"},
	{param = P_MIX, kind = .Knob, x = 921, y = 174, r = 24, label = "MIX"},
	{param = P_OUTPUT_TRIM, kind = .Knob, x = 1003, y = 174, r = 24, label = "OUTPUT"},
	{param = P_AUTO_MAKEUP, kind = .Button, x = 921, y = 272, label = "AUTO MAKEUP"},

	// DETECTOR
	{
		param = P_DETECTOR,
		kind = .Selector,
		x = 101,
		y = 385,
		r = 19,
		label = "MODE",
		options = {"PEAK", "RMS", "HYBRID"},
	},
	{
		param = P_TOPOLOGY,
		kind = .Toggle,
		x = 220,
		y = 380,
		label = "TOPOLOGY",
		options = {"FWD", "FBK"},
	},
	{param = P_STEREO_LINK, kind = .Knob, x = 338, y = 380, r = 21, label = "STEREO LINK"},
	{
		param = P_CHANNEL_MODE,
		kind = .Toggle,
		x = 456,
		y = 380,
		label = "CHANNEL",
		options = {"L/R", "M/S"},
	},
	{param = P_LOOKAHEAD, kind = .Knob, x = 575, y = 380, r = 21, label = "LOOKAHEAD"},

	// SIDECHAIN
	{
		param = P_SC_SOURCE,
		kind = .Toggle,
		x = 725,
		y = 380,
		label = "SC SOURCE",
		options = {"INT", "EXT"},
	},
	{param = P_SC_HIGHPASS, kind = .Knob, x = 850, y = 380, r = 21, label = "SC HIGH-PASS"},
	{param = P_SC_LISTEN, kind = .Button, x = 975, y = 392, label = "SC LISTEN"},
}

Bay :: struct {
	x, w:  f32,
	y, h:  f32,
	label: string,
}

BAYS := [?]Bay {
	{28, 102, HEADER, 220, "INPUT"},
	{130, 310, HEADER, 220, "COMPRESSOR"},
	{440, 186, HEADER, 220, "ENVELOPE"},
	{626, 164, HEADER, 220, "TRANSFER"},
	{790, 212, HEADER, 220, "OUTPUT"},
	{28, 620, TIER_SPLIT, 138, "DETECTOR"},
	{648, 404, TIER_SPLIT, 138, "SIDECHAIN"},
	{1052, 100, HEADER, 358, "METERS"},
}

// Transfer window
WINDOW_X :: f32(640)
WINDOW_Y :: f32(126)
WINDOW_W :: f32(136)
WINDOW_H :: f32(110)

// Meter ladders
METER_SEGMENTS :: 16
METER_TOP :: f32(140)
METER_SEG_H :: f32(12)
METER_SEG_GAP :: f32(2)
GR_LADDER_X :: f32(1068)
OUT_LADDER_X :: f32(1116)
LADDER_W :: f32(20)
METER_SCALE_X :: f32(1112)

// Maker dataplate
PLATE_X :: f32(46)
PLATE_Y :: f32(24)
PLATE_W :: f32(152)
PLATE_H :: f32(44)

// Knob sweep: 240 degrees, from 7 o'clock round to 5 o'clock.
SWEEP_START :: f32(-120)
SWEEP_END :: f32(120)

// Returns the control under a point, or -1.
hit_test :: proc(x, y: f32) -> int {
	for control, index in CONTROLS {
		switch control.kind {
		case .Knob, .Hero, .Selector:
			dx := x - control.x
			dy := y - control.y
			if dx * dx + dy * dy <= (control.r + 5) * (control.r + 5) {
				return index
			}
		case .Button:
			if abs(x - control.x) <= BUTTON_W / 2 + 2 && abs(y - control.y) <= BUTTON_H / 2 + 2 {
				return index
			}
		case .Toggle:
			if abs(x - control.x) <= TOGGLE_W / 2 + 3 && abs(y - control.y) <= TOGGLE_H / 2 + 2 {
				return index
			}
		}
	}
	return -1
}
