package gui

import "core:os"
import nvg "vendor:nanovg"

// Fonts.
//
// The design calls for a condensed industrial face for legend and a monospace for
// readouts. Arial Narrow and Monaco both ship with macOS as plain .ttf files, which
// matters because nanovg's loader is stb_truetype — it cannot open a .ttc collection
// (Helvetica.ttc) without an explicit face offset.
//
// These are loaded from the system rather than embedded because Arial is not
// redistributable. If a machine is missing one, the fallbacks below keep the panel
// legible rather than blank; a shipping build should embed a licensed face instead.

FONT_LEGEND :: "legend"
FONT_MONO :: "mono"

LEGEND_CANDIDATES := [?]string {
	"/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf",
	"/System/Library/Fonts/Supplemental/Arial Bold.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/System/Library/Fonts/Geneva.ttf",
}

MONO_CANDIDATES := [?]string {
	"/System/Library/Fonts/Monaco.ttf",
	"/System/Library/Fonts/Menlo.ttc", // last resort; may fail to parse
	"/System/Library/Fonts/Supplemental/Courier New.ttf",
}

load_fonts :: proc(vg: ^nvg.Context) -> bool {
	legend := load_first(vg, FONT_LEGEND, LEGEND_CANDIDATES[:])
	mono := load_first(vg, FONT_MONO, MONO_CANDIDATES[:])

	// Readouts can fall back to the legend face; an unnamed font id makes nanovg draw
	// nothing at all, which would look like a broken panel rather than a missing font.
	if mono < 0 && legend >= 0 {
		load_first(vg, FONT_MONO, LEGEND_CANDIDATES[:])
	}
	return legend >= 0
}

@(private = "file")
load_first :: proc(vg: ^nvg.Context, name: string, candidates: []string) -> int {
	for path in candidates {
		if !os.exists(path) {
			continue
		}
		id := nvg.CreateFont(vg, name, path)
		if id >= 0 {
			return id
		}
	}
	return -1
}
