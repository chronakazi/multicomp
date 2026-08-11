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

// `brush` is the tiled striation texture from `create_brush`. Zero is nanovg's own "no
// such image", and falls back to stroking the lines individually. The chassis never
// changes, but it is redrawn every frame regardless, so what it costs is the floor under
// the whole panel's frame time.
draw_panel :: proc(vg: ^nvg.Context, brush: int = 0) {
	draw_cheeks(vg)
	draw_faceplate(vg, brush)
	draw_divisions(vg)
}

// The brushed texture as a repeating image: one lit column every BRUSH_PERIOD points.
//
// Drawn as individual hairlines this cost 0.80 ms of a 1.68 ms repaint - 95% of the
// chassis, and four times the entire DSP - because nanovg re-tessellates ~380 separate
// stroked paths on every frame. As one tiled fill it is 0.04 ms for the same striations.
//
// The handle belongs to the nanovg context that created it, so it is stored per Gui
// rather than in a package global: two plugin instances have two contexts.
//
// Returns 0 if the texture could not be created, which is nanovg's own invalid handle -
// valid ids start at 1, so a `>= 0` test would happily draw with a dead one.
BRUSH_PERIOD :: 3

create_brush :: proc(vg: ^nvg.Context) -> int {
	// Straight (non-premultiplied) RGBA, matching what nvg.RGBA(255,255,255,6) meant when
	// these were strokes - nanovg premultiplies an image without the PREMULTIPLIED flag.
	texels: [BRUSH_PERIOD * 4]u8
	texels[0], texels[1], texels[2], texels[3] = 255, 255, 255, 6
	return nvg.CreateImageRGBA(vg, BRUSH_PERIOD, 1, {.REPEAT_X, .REPEAT_Y, .NEAREST}, texels[:])
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
draw_faceplate :: proc(vg: ^nvg.Context, brush: int) {
	paint := nvg.LinearGradient(0, 0, 0, HEIGHT, hex(PANEL_TOP), hex(PANEL_BOTTOM))
	nvg.BeginPath(vg)
	nvg.Rect(vg, CHEEK, 0, WIDTH - CHEEK * 2, HEIGHT)
	nvg.FillPaint(vg, paint)
	nvg.Fill(vg)

	// Brushed texture: fine vertical striations. Anchored at CHEEK so the lit columns
	// land on the same coordinates the stroked version put them on.
	if brush > 0 {
		texture := nvg.ImagePattern(CHEEK, 0, BRUSH_PERIOD, 1, 0, brush, 1)
		nvg.BeginPath(vg)
		nvg.Rect(vg, CHEEK, 0, WIDTH - CHEEK * 2, HEIGHT)
		nvg.FillPaint(vg, texture)
		nvg.Fill(vg)
		return
	}

	// No texture: stroke them. Only reached if image creation failed, which would mean
	// the GL stack is in trouble anyway - but a bare faceplate is better than none.
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
		x += BRUSH_PERIOD
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
