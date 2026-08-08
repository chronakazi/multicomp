package gui

import "core:math"
import nvg "vendor:nanovg"

// Everything above the chassis: bay legends, the dataplate, the wordmark, the controls,
// the transfer window and the meters.

draw_controls :: proc(g: ^Gui) {
	vg := g.vg
	draw_header(vg)
	draw_bay_legends(vg)

	buffer: [64]u8
	for control, index in CONTROLS {
		hot := g.drag.control == index
		switch control.kind {
		case .Knob, .Hero:
			value := f32(g.bridge.normalized(g.bridge.user, control.param))
			text := g.bridge.text(g.bridge.user, control.param, buffer[:])
			draw_knob(vg, control, value, text, hot)
		case .Button:
			on := g.bridge.choice(g.bridge.user, control.param) != 0
			draw_button(vg, control, on, hot)
		case .Toggle:
			draw_toggle(vg, control, g.bridge.choice(g.bridge.user, control.param), hot)
		case .Selector:
			draw_selector(vg, control, g.bridge.choice(g.bridge.user, control.param), hot)
		}
	}

	draw_window(g)
	draw_meters(g)
}

//
// Header
//

@(private = "file")
draw_header :: proc(vg: ^nvg.Context) {
	// Engraved dataplate
	plate := nvg.LinearGradient(
		PLATE_X,
		PLATE_Y,
		PLATE_X,
		PLATE_Y + PLATE_H,
		nvg.RGBA(0, 0, 0, 87),
		nvg.RGBA(255, 255, 255, 11),
	)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, PLATE_X, PLATE_Y, PLATE_W, PLATE_H, 2.5)
	nvg.FillPaint(vg, plate)
	nvg.Fill(vg)

	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, PLATE_X + 0.5, PLATE_Y + 0.5, PLATE_W - 1, PLATE_H - 1, 2.2)
	nvg.StrokeColor(vg, nvg.RGBA(0, 0, 0, 140))
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, PLATE_X + 1.5, PLATE_Y + 1.5, PLATE_W - 3, PLATE_H - 3, 1.6)
	nvg.StrokeColor(vg, nvg.RGBA(255, 255, 255, 28))
	nvg.Stroke(vg)

	centre := PLATE_X + PLATE_W / 2
	draw_rivet(vg, PLATE_X + 11, PLATE_Y + PLATE_H / 2)
	draw_rivet(vg, PLATE_X + PLATE_W - 11, PLATE_Y + PLATE_H / 2)

	label_text(vg, centre, PLATE_Y + 17, "FOESOFT AUDIO", 11.5, hex(LEGEND))

	nvg.BeginPath(vg)
	nvg.MoveTo(vg, centre - 44, PLATE_Y + 23)
	nvg.LineTo(vg, centre + 44, PLATE_Y + 23)
	nvg.StrokeColor(vg, nvg.RGBA(230, 225, 212, 51))
	nvg.StrokeWidth(vg, 0.7)
	nvg.Stroke(vg)

	label_text(vg, centre, PLATE_Y + 34, "MODEL MC-1 - SER 0001", 8, hex(LEGEND_DIM))

	// Wordmark, right aligned
	nvg.FontFace(vg, FONT_LEGEND)
	nvg.FontSize(vg, 40)
	nvg.FillColor(vg, hex(LEGEND))
	nvg.TextAlign(vg, .RIGHT, .BASELINE)
	nvg.Text(vg, WIDTH - CHEEK - 22, 52, "MULTICOMP")

	nvg.FontSize(vg, 10)
	nvg.FillColor(vg, hex(LEGEND_DIM))
	nvg.Text(vg, WIDTH - CHEEK - 22, 68, "PROGRAM COMPRESSOR")
}

@(private = "file")
draw_rivet :: proc(vg: ^nvg.Context, cx, cy: f32) {
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy, 3)
	nvg.FillColor(vg, nvg.RGBA(0, 0, 0, 128))
	nvg.Fill(vg)

	dome := nvg.RadialGradient(cx - 0.8, cy - 1, 0.4, 3, hex(NICKEL_LIGHT), hex(NICKEL_DARK))
	nvg.BeginPath(vg)
	nvg.Circle(vg, cx, cy - 0.3, 2.4)
	nvg.FillPaint(vg, dome)
	nvg.Fill(vg)
}

@(private = "file")
draw_bay_legends :: proc(vg: ^nvg.Context) {
	for bay in BAYS {
		centre := bay.x + bay.w / 2
		label_text(vg, centre, bay.y + 20, bay.label, 11.5, hex(LEGEND))

		nvg.BeginPath(vg)
		nvg.MoveTo(vg, bay.x + 14, bay.y + 27)
		nvg.LineTo(vg, bay.x + bay.w - 14, bay.y + 27)
		nvg.StrokeColor(vg, nvg.RGBA(230, 225, 212, 46))
		nvg.StrokeWidth(vg, 0.8)
		nvg.Stroke(vg)
	}
}

//
// Transfer window
//

@(private = "file")
draw_window :: proc(g: ^Gui) {
	vg := g.vg
	x, y, w, h := WINDOW_X, WINDOW_Y, WINDOW_W, WINDOW_H

	// Bezel
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x - 5, y - 5, w + 10, h + 10, 4)
	nvg.FillColor(vg, hex(COLLAR_DARK))
	nvg.Fill(vg)
	nvg.BeginPath(vg)
	nvg.RoundedRect(vg, x - 5, y - 5, w + 10, h + 10, 4)
	nvg.StrokeColor(vg, nvg.RGBA(255, 255, 255, 36))
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	nvg.BeginPath(vg)
	nvg.Rect(vg, x, y, w, h)
	nvg.FillColor(vg, hex(DISPLAY_BG))
	nvg.Fill(vg)

	nvg.Save(vg)
	nvg.Scissor(vg, x, y, w, h)

	// Grid
	nvg.StrokeWidth(vg, 1)
	nvg.StrokeColor(vg, nvg.RGBA(255, 182, 72, 26))
	for i in 1 ..< 6 {
		fi := f32(i)
		nvg.BeginPath(vg)
		nvg.MoveTo(vg, x + w * fi / 6, y)
		nvg.LineTo(vg, x + w * fi / 6, y + h)
		nvg.Stroke(vg)
		nvg.BeginPath(vg)
		nvg.MoveTo(vg, x, y + h * fi / 6)
		nvg.LineTo(vg, x + w, y + h * fi / 6)
		nvg.Stroke(vg)
	}

	// Unity reference
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, x, y + h)
	nvg.LineTo(vg, x + w, y)
	nvg.StrokeColor(vg, nvg.RGBA(255, 182, 72, 56))
	nvg.Stroke(vg)

	// The curve, sampled from the DSP's own gain computer so it cannot drift from what
	// the audio is actually doing.
	to_x :: proc(db: f32) -> f32 {return WINDOW_X + (db + 60) / 60 * WINDOW_W}
	to_y :: proc(db: f32) -> f32 {return WINDOW_Y + WINDOW_H - (db + 60) / 60 * WINDOW_H}

	nvg.BeginPath(vg)
	for i in 0 ..= 120 {
		db := -60 + 60 * f32(i) / 120
		out := f32(g.bridge.curve(g.bridge.user, f64(db)))
		px, py := to_x(db), to_y(out)
		if i == 0 {
			nvg.MoveTo(vg, px, py)
		} else {
			nvg.LineTo(vg, px, py)
		}
	}
	nvg.StrokeColor(vg, hex(DISPLAY_INK))
	nvg.StrokeWidth(vg, 1.6)
	nvg.LineJoin(vg, .ROUND)
	nvg.Stroke(vg)

	nvg.Restore(vg)

	// Readout
	gr := g.bridge.meter(g.bridge.user, .Gain_Reduction)
	nvg.FontFace(vg, FONT_LEGEND)
	nvg.FontSize(vg, 10)
	nvg.FillColor(vg, hex(DISPLAY_INK))
	nvg.TextAlign(vg, .LEFT, .BASELINE)
	nvg.Text(vg, x + 7, y + 17, "GR")

	buffer: [32]u8
	nvg.FontFace(vg, FONT_MONO)
	nvg.FontSize(vg, 12)
	nvg.TextAlign(vg, .RIGHT, .BASELINE)
	nvg.Text(vg, x + w - 7, y + 17, format_db(buffer[:], -gr))

	label_text(vg, x + w / 2, y + h + 26, "IN -60 - 0 dB", 9, hex(LEGEND_DIM))
}

//
// Meters
//

@(private = "file")
draw_meters :: proc(g: ^Gui) {
	gr := g.bridge.meter(g.bridge.user, .Gain_Reduction)
	out := g.bridge.meter(g.bridge.user, .Output)

	// Gain reduction spans 0..18 dB across the ladder; output spans +6..-30 dBFS.
	gr_lit := int(math.round(clamp(gr / 18, 0, 1) * METER_SEGMENTS))
	out_lit := int(math.round(clamp((out + 30) / 36, 0, 1) * METER_SEGMENTS))

	draw_ladder(g.vg, GR_LADDER_X, gr_lit, .Gain_Reduction)
	draw_ladder(g.vg, OUT_LADDER_X, out_lit, .Output)
	draw_meter_scale(g.vg)
}

// Small helper so the readout does not need the plugin's formatter.
format_db :: proc(buffer: []u8, value: f64) -> string {
	v := value
	if v > -0.05 && v < 0.05 {
		v = 0
	}
	negative := v < 0
	if negative {
		v = -v
	}
	whole := int(v)
	frac := int((v - f64(whole)) * 10 + 0.5)
	if frac >= 10 {
		whole += 1
		frac = 0
	}

	n := 0
	write :: proc(buffer: []u8, n: ^int, b: u8) {
		if n^ < len(buffer) {
			buffer[n^] = b
			n^ += 1
		}
	}
	if negative {
		write(buffer, &n, '-')
	}
	if whole >= 100 {
		write(buffer, &n, u8('0' + whole / 100))
	}
	if whole >= 10 {
		write(buffer, &n, u8('0' + (whole / 10) % 10))
	}
	write(buffer, &n, u8('0' + whole % 10))
	write(buffer, &n, '.')
	write(buffer, &n, u8('0' + frac))
	write(buffer, &n, ' ')
	write(buffer, &n, 'd')
	write(buffer, &n, 'B')
	return string(buffer[:n])
}
