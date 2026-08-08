# multicomp — implementation plan

A full-featured single-band compressor in CLAP format, written in Odin, macOS arm64.
DSP is structured so bands become a slice — multiband is an additive step later, not a rewrite.

Read `CLAUDE.md` first for environment, build commands, style, and CLAP+Odin gotchas.

## Architecture

Three layers, deliberately separated so the hard parts can be tested in isolation.

```
src/dsp/      pure DSP. No CLAP types, no allocation, no context.
              proc "contextless" throughout. Testable with `odin test`.

src/plugin/   CLAP glue. Entry, factory, extensions, the parameter table,
              state serialisation, and the lock-free GUI<->audio channels.

src/gui/      Cocoa child-view embedding, GL context, nanovg drawing, widgets.
              Talks to the audio thread only through the channels in plugin/.
```

The rule that keeps this honest: `dsp/` must never import `clap`. If a compressor
change requires touching CLAP types, it belongs in `plugin/`.

### Threading model

- **Audio thread** owns all DSP state. Parameters reach it *only* as CLAP events, via
  `process()` and `params.flush()`. Never by the GUI writing shared state.
- **GUI thread** owns all view state. It writes parameter edits into a single-producer
  ring buffer; `process()`/`flush()` drain it and emit `PARAM_VALUE` events on
  `out_events` so the host records automation, wrapped in `PARAM_GESTURE_BEGIN/END`.
- **Meters** flow the other way as plain relaxed atomics (single writer, single reader).
  Dropped updates are fine — it is a meter.

## Parameter set

| Param | Range | Notes |
|---|---|---|
| Bypass | on/off | `PARAM_IS_BYPASS` |
| Input trim | −24 … +24 dB | |
| Threshold | −60 … 0 dB | |
| Ratio | 1:1 … 20:1, ∞ | ∞ at the top of the range = limiting |
| Knee | 0 … 24 dB | soft knee width |
| Attack | 0.1 … 300 ms | |
| Release | 5 … 3000 ms | |
| Auto release | on/off | program-dependent, two-stage |
| Detector | Peak / RMS / Hybrid | `PARAM_IS_ENUM` + `IS_STEPPED` |
| Topology | Feed-forward / Feedback | feedback for a more "vintage" curve |
| Stereo link | 0 … 100 % | 100 % = fully linked detector |
| Channel mode | Stereo / Mid-Side | |
| Lookahead | 0 … 10 ms | reports latency via `clap.latency` |
| Sidechain source | Internal / External | external SC audio port |
| SC high-pass | 20 … 500 Hz | keeps kick out of the detector |
| SC listen | on/off | audition the detector signal |
| Makeup | −12 … +24 dB | |
| Auto makeup | on/off | derived from threshold + ratio |
| Mix | 0 … 100 % | parallel compression |
| Output trim | −24 … +24 dB | |

Every parameter is `AUTOMATABLE`; continuous ones are also `MODULATABLE`. The table is a
single source of truth — id, name, module, range, flags, unit, and the value↔text
formatters live in one array in `plugin/params.odin`, and `count`/`get_info` read from it.
That keeps `clap.params` and the GUI from drifting apart.

## DSP design

Standard log-domain feed-forward topology, following Giannoulis, Massberg & Reiss,
*Digital Dynamic Range Compressor Design — A Tutorial and Analysis* (JAES 2012). Per sample:

1. **Detect** — peak (`abs`), RMS (one-pole mean square), or hybrid; stereo-linked by
   blending the per-channel detector with the max across channels by the link amount.
2. **To dB** — `20*log10`, floored to avoid `-inf`.
3. **Gain computer** — static curve with a quadratic soft knee: below `T − W/2` no gain
   change; within the knee, interpolate; above `T + W/2`, `(1/ratio − 1) * (x − T)`.
4. **Smooth** — *decoupled* peak detector (branching smoothed): a release-only stage feeding
   an attack/release stage. This avoids the level-dependent attack of the naive branching
   design and is what makes a compressor sound like a compressor.
   Coefficients: `α = exp(-1 / (τ · fs))`, recomputed only when the time constant changes.
5. **Apply** — convert the smoothed gain-reduction dB back to linear, apply to the
   (lookahead-delayed) main path, then makeup, then mix, then output trim.

Building blocks in `dsp/`: `Biquad` (SC filter now, Linkwitz-Riley crossovers later),
`Delay_Line` (lookahead), `Envelope_Follower`, `Gain_Computer`, `Smoother` (one-pole
parameter smoothing so knob moves don't zipper).

**Multiband seam**: the per-band state lives in a `Compressor_Band` struct, and the plugin
holds `bands: []Compressor_Band` with `len == 1` today. Going multiband means adding a
crossover and growing that slice plus the parameter table — the band DSP itself is untouched.

## Phases

Each phase ends with `clap-validator validate` green (0 failed, 0 warnings). That is the gate.

**Phase 0 — Skeleton that validates. ✅ DONE.** Project layout, `build.sh` (build, bundle,
validate, install), entry, factory, descriptor, stereo audio ports, one placeholder gain
parameter, state save/load with correctly looped partial reads/writes, and sample-accurate
event splitting in `process`. Verified: `./build.sh --validate` →
**21 tests, 15 passed, 0 failed, 6 skipped, 0 warnings.**

**Phase 1 — Parameter system.** Full table above, `value_to_text`/`text_to_value` with real
units (`-12.5 dB`, `4.0:1`, `∞:1`, `35 ms`), versioned state serialisation. Gate: the
validator's `state-reproducibility-*` and `param-conversions` tests pass.

**Phase 2 — DSP, headless.** All of `dsp/`, with `odin test` covering: static curve shape
at known threshold/ratio/knee, attack/release time constants measured against a step input,
and RMS detector convergence. No CLAP involvement — fast to iterate.

**Phase 3 — Wire it up.** Sample-accurate event splitting in `process`, parameter smoothing,
lookahead delay with `clap.latency` reporting, `clap.tail`. Gate: validator clean, plus a
first listen in a DAW.

**Phase 4 — Routing features.** External sidechain audio port, SC high-pass and listen,
stereo link, mid/side, mix, auto-makeup, auto-release.

**Phase 5 — GUI shell.** Create a child `NSView` under the host's parent view, attach an
`NSOpenGLContext`, init nanovg, clear to a colour, repaint from `clap.timer-support`
(host-driven — avoids running our own thread). Implement `clap.gui` fully:
`is_api_supported`/`create`/`destroy`/`set_parent`/`get_size`/`can_resize`/`set_size`/
`show`/`hide`. Gate: opens and closes cleanly in a DAW, repeatedly, with no leak.

**Phase 6 — Widgets and binding.** Knob, toggle, enum selector, drag-and-type value entry,
bound to the parameter table through the ring buffer with proper gesture begin/end.
This is where "full GUI" is actually earned.

**Phase 7 — Visual feedback.** Input/output/GR meters, the transfer curve with the live
operating point drawn on it, and a scrolling gain-reduction history. These are what make a
compressor usable, and they are the reason nanovg was chosen over hand-rolled drawing.

**Phase 8 — Polish.** Presets (`clap.preset-load`), `clap.remote-controls` for hardware
surfaces, param modulation, GUI resize, and a proper `Info.plist` + code signing for
distribution.

## Feasibility notes

Verified this session, not assumed:

- The bindings are ABI-correct — 137/137 struct layouts, 228/228 function pointers,
  171 enum values, 93 string constants, all matching CLAP 1.2.10 exactly.
- An Odin-built `.clap` loads in a real host (`clap-info`) and passes the official
  validator clean.
- `vendor:nanovg` + `vendor:nanovg/gl` + `core:sys/darwin/Foundation` (NSView) +
  `vendor:darwin/Metal` all typecheck on macOS arm64.
- Odin's objc runtime bindings expose `objc_allocateClassPair` / `class_addMethod`, so the
  runtime `NSView` subclass needed for event handling is achievable, with in-tree precedent
  in `NSApplication.odin` and `MetalKit.odin`.

Open risks, with mitigations:

- **OpenGL is deprecated on macOS.** It works today and will for the foreseeable future.
  Keep all GL calls behind a thin renderer interface in `gui/` so a Metal backend is a
  contained swap, not a rewrite. `vendor:darwin/Metal` and `QuartzCore` are already present.
- **No plugin framework.** Everything JUCE or nih-plug would give you — parameter plumbing,
  GUI embedding, state — we write. Estimate ~800–1200 lines of glue for a plugin this size.
  That is the cost of the learning exercise, and it is a one-time cost reusable across plugins.
- **Odin is on a nightly build.** Pin `dev-2026-08-nightly:902106f` and don't upgrade
  mid-phase; nightlies do break.
- **Debugging inside a DAW is painful.** Always reproduce in `clap-validator` first — it
  catches threading and state bugs faster than any host will.

## Re-verifying the bindings after a CLAP bump

The check is mechanical and worth repeating whenever `free-audio/clap` is updated:

1. Generate a C file that declares one variable of every `clap_*_t` type, then
   `clang -Xclang -fdump-record-layouts-complete -fsyntax-only` it. Note that
   `-fdump-record-layouts` alone emits almost nothing under `-fsyntax-only`.
2. Generate an Odin program that calls `reflect.struct_fields_zipped` over every binding
   struct and prints `size_of`, `align_of`, and each field offset.
3. Diff, mapping `clap_event_note_t` → `Event_Note` (strip `clap_`/`_t`, capitalise parts).
   Watch for `FD`-style acronyms that break naive capitalisation.
4. For function pointers, compare arity and return-vs-void — struct layout only sees an
   8-byte pointer and will not catch a wrong signature. Careful with `void *` returns,
   which look like `void` to a naive parser.
5. For enums, compile a C program that prints every `CLAP_*` constant and compare against
   `reflect.enum_field_names`/`enum_field_values`.
