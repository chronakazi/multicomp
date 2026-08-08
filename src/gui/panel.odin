package gui

// The faceplate itself. Phase 5 draws only the chassis — walnut cheeks, the graphite
// plate and its engraved divisions. Controls arrive in Phase 6, ported from the geometry
// in design/panel.html, which is authored at exactly WIDTH x HEIGHT so its coordinates
// carry over unchanged.

import nvg "vendor:nanovg"

Rgb :: struct {
	r, g, b: f32,
}

hex :: proc(value: u32) -> nvg.Color {
	return nvg.RGB(u8(value >> 16), u8(value >> 8), u8(value))
}

// Graphite finish, from the approved design. The clear colour is the mid panel tone, so
// any area nanovg has not covered still reads as part of the box.
PANEL_CLEAR :: Rgb{0x34 / 255.0, 0x38 / 255.0, 0x3b / 255.0}

PANEL_TOP :: 0x4a4e52
PANEL_MID :: 0x34383b
PANEL_BOTTOM :: 0x2a2d30
WALNUT_LIGHT :: 0x6b4426
WALNUT_DARK :: 0x3d2515
LEGEND :: 0xe6e1d4

CHEEK :: 28 // walnut end cap width
HEADER :: 86 // header band height
TIER_SPLIT :: 306 // upper/lower tier divider

draw_panel :: proc(vg: ^nvg.Context) {
	draw_cheeks(vg)
	draw_faceplate(vg)
	draw_divisions(vg)
}

@(private = "file")
draw_cheeks :: proc(vg: ^nvg.Context) {
	for x in ([?]f32{0, WIDTH - CHEEK}) {
		paint := nvg.LinearGradient(x, 0, x + CHEEK, 0, hex(WALNUT_DARK), hex(WALNUT_LIGHT))
		nvg.BeginPath(vg)
		nvg.Rect(vg, x, 0, CHEEK, HEIGHT)
		nvg.FillPaint(vg, paint)
		nvg.Fill(vg)
	}
}

@(private = "file")
draw_faceplate :: proc(vg: ^nvg.Context) {
	paint := nvg.LinearGradient(0, 0, 0, HEIGHT, hex(PANEL_TOP), hex(PANEL_BOTTOM))
	nvg.BeginPath(vg)
	nvg.Rect(vg, CHEEK, 0, WIDTH - CHEEK * 2, HEIGHT)
	nvg.FillPaint(vg, paint)
	nvg.Fill(vg)

	// Brushed texture: fine vertical striations, cheap enough to redraw every frame.
	nvg.Save(vg)
	nvg.Scissor(vg, CHEEK, 0, WIDTH - CHEEK * 2, HEIGHT)
	nvg.StrokeWidth(vg, 1)
	x := f32(CHEEK)
	for x < WIDTH - CHEEK {
		nvg.BeginPath(vg)
		nvg.MoveTo(vg, x, 0)
		nvg.LineTo(vg, x, HEIGHT)
		nvg.StrokeColor(vg, nvg.RGBA(255, 255, 255, 6))
		nvg.Stroke(vg)
		x += 3
	}
	nvg.Restore(vg)
}

// An engraved line is a dark groove with a lit lower lip; drawing both is what makes it
// read as cut into the metal rather than painted on.
@(private = "file")
engrave_h :: proc(vg: ^nvg.Context, x0, x1, y: f32) {
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, x0, y)
	nvg.LineTo(vg, x1, y)
	nvg.StrokeColor(vg, nvg.RGBA(0, 0, 0, 108))
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	nvg.BeginPath(vg)
	nvg.MoveTo(vg, x0, y + 1)
	nvg.LineTo(vg, x1, y + 1)
	nvg.StrokeColor(vg, nvg.RGBA(255, 255, 255, 23))
	nvg.Stroke(vg)
}

@(private = "file")
engrave_v :: proc(vg: ^nvg.Context, x, y0, y1: f32) {
	nvg.BeginPath(vg)
	nvg.MoveTo(vg, x, y0)
	nvg.LineTo(vg, x, y1)
	nvg.StrokeColor(vg, nvg.RGBA(0, 0, 0, 115))
	nvg.StrokeWidth(vg, 1)
	nvg.Stroke(vg)

	nvg.BeginPath(vg)
	nvg.MoveTo(vg, x + 1, y0)
	nvg.LineTo(vg, x + 1, y1)
	nvg.StrokeColor(vg, nvg.RGBA(255, 255, 255, 18))
	nvg.Stroke(vg)
}

// Bay boundaries, straight from the design. Phase 6 fills these with controls.
UPPER_BAYS :: [?]f32{130, 440, 626, 790}
LOWER_BAYS :: [?]f32{648}
METER_X :: 1052

@(private = "file")
draw_divisions :: proc(vg: ^nvg.Context) {
	engrave_h(vg, CHEEK, WIDTH - CHEEK, HEADER)
	engrave_h(vg, CHEEK, METER_X, TIER_SPLIT)

	for x in UPPER_BAYS {
		engrave_v(vg, x, HEADER + 6, TIER_SPLIT - 6)
	}
	for x in LOWER_BAYS {
		engrave_v(vg, x, TIER_SPLIT + 6, HEIGHT - 22)
	}
	engrave_v(vg, METER_X, HEADER + 6, HEIGHT - 22)
}
