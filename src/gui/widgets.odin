package gui

import "core:math"
import nvg "vendor:nanovg"

// Widget drawing, ported from design/panel.html. Where that used SVG gradients and
// letter-spacing tricks, this uses nanovg paints and a condensed face, but the geometry
// and colours are the same numbers.

NICKEL_LIGHT :: 0xd7d3ca
NICKEL_MID :: 0xa9a49a
NICKEL_DARK :: 0x6f6b64
COLLAR_LIGHT :: 0x26282a
COLLAR_DARK :: 0x131415
LEGEND_DIM :: 0x9c9789
ENGRAVE_INK :: 0x1b1d1f
AMBER :: 0xff9e2c
AMBER_DIM :: 0x7a4a12
DISPLAY_BG :: 0x120e08
DISPLAY_INK :: 0xffb648

deg :: proc "contextless" (d: f32) -> f32 {
	return d * math.PI / 180
}

// Value 0..1 to pointer angle. Zero is straight up, matching nanovg's coordinate sense
// once the -90 degree offset is applied at the point of use.
sweep_angle :: proc "contextless" (t: f32) -> f32 {
	return deg(SWEEP_START + (SWEEP_END - SWEEP_START) * clamp(t, 0, 1))
}

@(private = "file")
polar :: proc "contextless" (cx, cy, r, angle: f32) -> (x, y: f32) {
	return cx + r * math.sin(angle), cy - r * math.cos(angle)
}

//
// Text
//

label_text :: proc(vg: ^nvg.Context, x, y: f32, text: string, size: f32, colour: nvg.Color) {
	nvg.FontFace(vg, FONT_LEGEND)
	nvg.FontSize(vg, size)
	nvg.FillColor(vg, colour)
	nvg.TextAlign(vg, .CENTER, .BASELINE)
	nvg.Text(vg, x, y, text)
}

readout_text :: proc(vg: ^nvg.Context, x, y: f32, text: string, size: f32, colour: nvg.Color) {
	nvg.FontFace(vg, FONT_MONO)
	nvg.FontSize(vg, size)
	nvg.FillColor(vg, colour)
	nvg.TextAlign(vg, .CENTER, .BASELINE)
	nvg.Text(vg, x, y, text)
}

//
// Knob
//

draw_knob :: proc(
	vg: ^nvg.Context,
	control: Control,
	value: f32,
	text: string,
	hot: bool,
) {
	cx, cy, r := control.x, control.y, control.r
	hero := control.kind == .Hero

	draw_tick_arc(vg, cx, cy, r, hero)

	// Seat shadow
	nvg.BeginPath(vg)
	nvg.Ellipse(vg, cx, cy + r * 0.16, r * 1.04, r)
	nvg.FillColor(vg, nvg.RGBA(0, 0, 0, 90))
	nvg.Fill(vg)

	// Collar
	collar := nvg.RadialGradient(cx, cy, r * 0.7, r, hex(COLLAR_LIGHT), hex(COLLAR_DARK))
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, r)
	nvg.FillPaint(vg, collar)
	nvg.Fill(vg)

	// Brushed cap
	cap_r := r - 2.5
	cap := nvg.LinearGradient(
		cx - cap_r,
		cy - cap_r,
		cx + cap_r,
		cy + cap_r,
		hex(NICKEL_LIGHT),
		hex(NICKEL_DARK),
	)
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, cap_r)
	nvg.FillPaint(vg, cap)
	nvg.Fill(vg)

	// Sheen from the upper left
	sheen := nvg.RadialGradient(
		cx - cap_r * 0.35,
		cy - cap_r * 0.4,
		cap_r * 0.1,
		cap_r * 1.1,
		nvg.RGBA(255, 255, 255, 130),
		nvg.RGBA(255, 255, 255, 0),
	)
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, cap_r)
	nvg.FillPaint(vg, sheen)
	nvg.Fill(vg)

	// Rim
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, cap_r)
	nvg.StrokeColor(vg, nvg.RGBA(255, 255, 255, hot ? 110 : 56))
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	// Pointer: a dark groove with an amber core, so it reads at a glance.
	angle := sweep_angle(value)
	x0, y0 := polar(cx, cy, r * (hero ? 0.34 : 0.28), angle)
	x1, y1 := polar(cx, cy, r - 6, angle)

	nvg.BeginPath(vg)
	nvg.MoveTo(vg, x0, y0)
	nvg.LineTo(vg, x1, y1)
	nvg.StrokeColor(vg, hex(ENGRAVE_INK))
	nvg.StrokeWidth(vg, hero ? 4.6 : 3.4)
	nvg.LineCap(vg, .ROUND)
	nvg.Stroke(vg)

	nvg.BeginPath(vg)
	nvg.MoveTo(vg, x0, y0)
	nvg.LineTo(vg, x1, y1)
	nvg.StrokeColor(vg, hex(AMBER))
	nvg.StrokeWidth(vg, hero ? 2.2 : 1.5)
	nvg.Stroke(vg)

	label_text(vg, cx, cy + r + 20, control.label, 11, hex(LEGEND))
	readout_text(vg, cx, cy + r + 33, text, 10, hex(LEGEND_DIM))
}

@(private = "file")
draw_tick_arc :: proc(vg: ^nvg.Context, cx, cy, r: f32, hero: bool) {
	count := hero ? 21 : 11
	nvg.LineCap(vg, .ROUND)
	for i in 0 ..< count {
		t := f32(i) / f32(count - 1)
		angle := sweep_angle(t)
		major := i == 0 || i == count - 1 || (hero && i == (count - 1) / 2)

		x0, y0 := polar(cx, cy, r + 4, angle)
		x1, y1 := polar(cx, cy, r + (major ? TICK_REACH : 8), angle)

		nvg.BeginPath(vg)
		nvg.MoveTo(vg, x0, y0)
		nvg.LineTo(vg, x1, y1)
		nvg.StrokeColor(vg, nvg.RGBA(156, 151, 137, major ? 240 : 140))
		nvg.StrokeWidth(vg, major ? 1.6 : 1)
		nvg.Stroke(vg)
	}
}

//
// Button
//

draw_button :: proc(vg: ^nvg.Context, control: Control, on: bool, hot: bool) {
	cx, cy := control.x, control.y
	x := cx - BUTTON_W / 2
	y := cy - BUTTON_H / 2

	cap := nvg.LinearGradient(x, y, x, y + BUTTON_H, hex(NICKEL_LIGHT), hex(NICKEL_DARK))
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x, y, BUTTON_W, BUTTON_H, 3)
	nvg.FillPaint(vg, cap)
	nvg.Fill(vg)

	// Top bevel
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x + 1.5, y + 1.5, BUTTON_W - 3, BUTTON_H / 2, 2)
	nvg.FillColor(vg, nvg.RGBA(255, 255, 255, 46))
	nvg.Fill(vg)

	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x, y, BUTTON_W, BUTTON_H, 3)
	nvg.StrokeColor(vg, nvg.RGBA(0, 0, 0, hot ? 170 : 115))
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	draw_lamp(vg, cx, cy, 3.5, on)
	label_text(vg, cx, cy + BUTTON_H / 2 + 17, control.label, 11, hex(LEGEND))
}

draw_lamp :: proc(vg: ^nvg.Context, cx, cy, r: f32, on: bool) {
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, r + 2)
	nvg.FillColor(vg, hex(COLLAR_DARK))
	nvg.Fill(vg)

	if on {
		glow := nvg.RadialGradient(cx, cy, r, r + 7, nvg.RGBA(255, 158, 44, 150), nvg.RGBA(255, 158, 44, 0))
		nvg.BeginPath(vg)
		nvg.Circle(vg, cx, cy, r + 7)
		nvg.FillPaint(vg, glow)
		nvg.Fill(vg)

		nvg.BeginPath(vg)
		nvg.Circle(vg, cx, cy, r)
		nvg.FillColor(vg, hex(AMBER))
		nvg.Fill(vg)

		nvg.BeginPath(vg)
		nvg.Circle(vg, cx - r * 0.3, cy - r * 0.3, r * 0.42)
		nvg.FillColor(vg, nvg.RGBA(255, 255, 255, 180))
		nvg.Fill(vg)
	} else {
		nvg.BeginPath(vg)
		nvg.Circle(vg, cx, cy, r)
		nvg.FillColor(vg, nvg.RGBA(122, 74, 18, 128))
		nvg.Fill(vg)
	}
}

//
// Toggle
//

draw_toggle :: proc(vg: ^nvg.Context, control: Control, index: int, hot: bool) {
	cx, cy := control.x, control.y
	x := cx - TOGGLE_W / 2
	y := cy - TOGGLE_H / 2

	slot := nvg.LinearGradient(x, y, x, y + TOGGLE_H, hex(COLLAR_DARK), hex(COLLAR_LIGHT))
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x, y, TOGGLE_W, TOGGLE_H, 3)
	nvg.FillPaint(vg, slot)
	nvg.Fill(vg)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x, y, TOGGLE_W, TOGGLE_H, 3)
	nvg.StrokeColor(vg, nvg.RGBA(0, 0, 0, hot ? 190 : 128))
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	lever_y := index == 0 ? cy - TOGGLE_H / 4 : cy + TOGGLE_H / 4
	lever := nvg.LinearGradient(
		x,
		lever_y - 9,
		x,
		lever_y + 9,
		hex(NICKEL_LIGHT),
		hex(NICKEL_DARK),
	)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x + 2.5, lever_y - 9, TOGGLE_W - 5, 18, 2.5)
	nvg.FillPaint(vg, lever)
	nvg.Fill(vg)

	nvg.FontFace(vg, FONT_LEGEND)
	nvg.FontSize(vg, 9.5)
	nvg.TextAlign(vg, .LEFT, .MIDDLE)
	for option, i in control.options {
		nvg.FillColor(vg, i == index ? hex(LEGEND) : hex(LEGEND_DIM))
		nvg.Text(vg, cx + 15, i == 0 ? cy - TOGGLE_H / 4 : cy + TOGGLE_H / 4, option)
	}

	label_text(vg, cx + 4, cy + TOGGLE_H / 2 + 22, control.label, 11, hex(LEGEND))
}

//
// Rotary selector
//

draw_selector :: proc(vg: ^nvg.Context, control: Control, index: int, hot: bool) {
	cx, cy, r := control.x, control.y, control.r
	count := len(control.options)
	LABEL_R :: f32(39)

	nvg.LineCap(vg, .ROUND)
	for option, i in control.options {
		t := count == 1 ? f32(0.5) : f32(i) / f32(count - 1)
		angle := sweep_angle(t)

		// Short stubs: a longer tick puts its endpoint inside the label's box at 120
		// degrees, because moving out along a diagonal radius buys only half as much
		// vertical separation as it does radial.
		x0, y0 := polar(cx, cy, r + 3, angle)
		x1, y1 := polar(cx, cy, r + 6, angle)
		nvg.BeginPath(vg)
		nvg.MoveTo(vg, x0, y0)
		nvg.LineTo(vg, x1, y1)
		nvg.StrokeColor(vg, hex(LEGEND_DIM))
		nvg.StrokeWidth(vg, 1.4)
		nvg.Stroke(vg)

		lx, ly := polar(cx, cy, LABEL_R, angle)
		label_text(vg, lx, ly + 3, option, 9.5, i == index ? hex(LEGEND) : hex(LEGEND_DIM))
	}

	collar := nvg.RadialGradient(cx, cy, r * 0.7, r, hex(COLLAR_LIGHT), hex(COLLAR_DARK))
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, r)
	nvg.FillPaint(vg, collar)
	nvg.Fill(vg)

	cap_r := r - 2.5
	cap := nvg.LinearGradient(
		cx - cap_r,
		cy - cap_r,
		cx + cap_r,
		cy + cap_r,
		hex(NICKEL_LIGHT),
		hex(NICKEL_DARK),
	)
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, cap_r)
	nvg.FillPaint(vg, cap)
	nvg.Fill(vg)
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, cap_r)
	nvg.StrokeColor(vg, nvg.RGBA(255, 255, 255, hot ? 110 : 56))
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	t := count <= 1 ? f32(0.5) : f32(index) / f32(count - 1)
	angle := sweep_angle(t)
	px, py := polar(cx, cy, r - 5, angle)
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, cx, cy)
	nvg.LineTo(vg, px, py)
	nvg.StrokeColor(vg, hex(ENGRAVE_INK))
	nvg.StrokeWidth(vg, 3.4)
	nvg.Stroke(vg)
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, cx, cy)
	nvg.LineTo(vg, px, py)
	nvg.StrokeColor(vg, hex(AMBER))
	nvg.StrokeWidth(vg, 1.5)
	nvg.Stroke(vg)

	label_text(vg, cx, cy + r + 18, control.label, 11, hex(LEGEND))
}

//
// Meters
//

// `lit` is how many segments are on, counted from the top for gain reduction and from the
// bottom for output — reduction grows downward, level grows upward.
draw_ladder :: proc(vg: ^nvg.Context, x: f32, lit: int, kind: Meter_Kind) {
	for i in 0 ..< METER_SEGMENTS {
		y := METER_TOP + f32(i) * (METER_SEG_H + METER_SEG_GAP)

		nvg.BeginPath(vg)
		nvg.RoundedRect(vg, x, y, LADDER_W, METER_SEG_H, 1.5)
		nvg.FillColor(vg, hex(COLLAR_DARK))
		nvg.Fill(vg)

		on: bool
		colour: nvg.Color
		if kind == .Gain_Reduction {
			on = i < lit
			colour = hex(AMBER)
		} else {
			on = (METER_SEGMENTS - 1 - i) < lit
			colour = i < 2 ? hex(0xff4d3d) : i < 5 ? hex(0xffc53d) : hex(0x54d67e)
		}

		nvg.BeginPath(vg)
		nvg.RoundedRect(vg, x + 1, y + 1, LADDER_W - 2, METER_SEG_H - 2, 1)
		if on {
			nvg.FillColor(vg, colour)
		} else {
			c := colour
			c.a = 0.09
			nvg.FillColor(vg, c)
		}
		nvg.Fill(vg)
	}
}

METER_SCALE := [?]string{"+6", "+3", "0", "-3", "-6", "-9", "-12", "-18", "-24", "-30"}

draw_meter_scale :: proc(vg: ^nvg.Context) {
	height := f32(METER_SEGMENTS) * (METER_SEG_H + METER_SEG_GAP) - METER_SEG_GAP
	nvg.FontFace(vg, FONT_LEGEND)
	nvg.FontSize(vg, 8)
	nvg.FillColor(vg, hex(LEGEND_DIM))
	// Right-aligned against the output ladder, which is what it measures. Gain reduction
	// needs no numbers: the exact figure is in the transfer window.
	nvg.TextAlign(vg, .RIGHT, .MIDDLE)
	for value, i in METER_SCALE {
		y := METER_TOP + 10 + f32(i) * (height / f32(len(METER_SCALE) - 1) * 0.94)
		nvg.Text(vg, METER_SCALE_X, y, value)
	}

	bottom := METER_TOP + height + 17
	label_text(vg, GR_LADDER_X + LADDER_W / 2, bottom, "GR", 10, hex(LEGEND))
	label_text(vg, OUT_LADDER_X + LADDER_W / 2, bottom, "OUT", 10, hex(LEGEND))
}
