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

**Phase 1 — Parameter system. ✅ DONE.** All 20 parameters above, as a `[Param_Id]Param`
enumerated array so lookup is O(1) and the table cannot fall out of order. Real unit
formatting and parsing (`-18.00 dB`, `4.0:1`, `∞:1`, `10.00 ms`, `20 Hz`, `100.0 %`,
`Feed-Forward`, `Off`), and versioned state written as explicit `(id, value)` pairs.
Verified: **21 tests, 16 passed, 0 failed, 5 skipped, 0 warnings** — `param-conversions`,
`param-fuzz-basic` and all three `state-reproducibility-*` tests pass. Separately
round-tripped every parameter at min/default/max through `value_to_text` →
`text_to_value` with 0 failures.

`process` still applies only bypass and the input/output trims; compression lands in
Phases 2–3.

**Phase 2 — DSP, headless. ✅ DONE.** `Gain_Computer` (quadratic soft knee), `Level_Detector`
(peak/RMS/hybrid), `Envelope_Follower` (smooth decoupled peak detector), `Biquad` (RBJ,
TDF-II), `Delay_Line` (caller-supplied storage, so dsp never allocates), `Smoother`, and
`Compressor_Band` composing them. `Detector_Mode` and `Topology_Mode` live here, not in
`plugin/`, since this is what switches on them.

Verified: **19 tests, all passing** (`odin test src/dsp`) — hard-knee curve at known
threshold/ratio, infinite-ratio limiting, knee continuity and monotonicity plus the local
slope sweeping 1 → 1/ratio, attack and release time constants measured against a step
input at 1/10/50 ms, RMS convergence on a sine to A/√2, biquad response at DC/corner/an
octave down, exact delay-line offsets, and band-level integration including feedback
topology settling at less reduction than feed-forward.

Note on soft knee: inside the knee the soft curve applies *more* cumulative reduction than
a hard knee, not less — it starts working at `T − W/2` and the two converge only at
`T + W/2`. The slope is gentler; the total reduction is not. A test asserting the opposite
was wrong and was corrected.

**Phase 3 — Wire it up. ✅ DONE.** The compressor is live. Events are applied at their exact
sample, gain staging is smoothed, lookahead delays the signal path while the detector reads
ahead, and both `clap.latency` and `clap.tail` report the delay.

Verified: validator **21 tests, 16 passed, 0 failed, 0 warnings**, plus `./build.sh --offline`
measuring real audio through the built plugin — every gain-reduction figure matches the
static curve to within 0.03 dB, bypass is bit-transparent, and the impulse delay at 5 ms
lookahead is exactly the 240 samples reported as latency.

Two design points worth remembering:

- Threshold, ratio and knee are *not* separately smoothed. A change to the curve reaches
  the output through the envelope follower, which is already smoothing at the user's attack
  and release times. Only the gain stages that bypass the envelope — input trim, makeup,
  output trim — get their own smoothers.
- `Lookahead` is deliberately neither automatable nor modulatable. CLAP requires reported
  latency to stay constant while active, so latency is latched at `activate`; a change asks
  the host for a main-thread callback, announces `clap.latency changed`, and requests a
  restart. Automating that would thrash the host, so it is a setup control.

Still not live: sidechain routing/filtering, variable stereo link, mid-side, mix,
auto-makeup, auto-release. These 8 parameters are flagged `NOT_IMPLEMENTED`
(`CLAP_PARAM_IS_HIDDEN`) so hosts do not offer controls that do nothing — 12 visible, 8
hidden. Detection is fully linked across channels, which is exactly what Stereo Link = 100%
means.

**Post-Phase-3 fix, found in DAW testing.** Ratio defaulted to 4:1 with threshold −18 dB, so
the plugin pulled ~9 dB off typical program material the moment it was inserted. The DSP was
correct — measured output matched the static curve to 0.01 dB at every level — but a
compressor must be transparent until the user asks for something. Ratio now defaults to 1:1,
where the gain computer returns its input unchanged at every level and the applied gain is
exactly 1.0. Threshold stays at −18 dB, so raising ratio is the single gesture that starts
compression. Guarded by a transparency check in `tools/offline`.

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
