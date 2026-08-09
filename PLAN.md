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

**Phase 4 — Routing features. ✅ DONE.** All 20 parameters are live; nothing carries
`NOT_IMPLEMENTED` any more.

- **External sidechain**: a second stereo input port, identified by not carrying `IS_MAIN`
  (CLAP has no dedicated sidechain flag). Falls back to the main input when the host has
  not connected anything, so selecting External never silently mutes the detector.
- **SC high-pass**: Butterworth biquad on the detector path only. The bottom of the range
  (20 Hz) means *off*, so the default detector path is genuinely unfiltered.
- **SC listen**: monitors the conditioned detector signal, post-filter.
- **Stereo link**: per-channel detectors and envelopes, each channel's level blended toward
  the loudest by the link amount, in dB.
- **Mid-side**: encode/decode around the gain stage, exactly lossless so M/S at 1:1 is
  transparent. The delay line still holds raw L/R, so bypass stays bit-exact.
- **Mix**: dry and wet both come off the same delay line, so the dry path is already
  latency-aligned and blending cannot comb-filter.
- **Auto makeup**: half the reduction the curve would apply at 0 dBFS. Half rather than
  full, because full compensation overshoots on real material that never sits at 0 dBFS.
- **Auto release**: the release coefficient slides between a fast branch and the user's
  setting according to current reduction depth — brief transients recover quickly,
  sustained passages recover at the full release time.

Verified: validator **21 tests, 16 passed, 0 failed, 0 warnings**; `odin test src/dsp`
**27 tests, all passing**; `./build.sh --offline` **33 checks, all passing**, including
external-sidechain ducking, SC high-pass rejection, link at 0/50/100%, mid-side
transparency and parallel-mix blending.

Coefficient updates (envelope `exp()`, biquad trig) are now cached against their inputs, so
sample-dense automation no longer recomputes them on every event boundary.

**Phase 5 — GUI shell. ✅ DONE.** A child `NSView` under the host's parent, an
`NSOpenGLContext`, nanovg drawing the faceplate chassis, repainted from
`clap.timer-support` at 60 Hz. `clap.gui` is implemented in full: `is_api_supported`,
`get_preferred_api`, `create`, `destroy`, `set_scale`, `get_size`, `can_resize`,
`get_resize_hints`, `adjust_size`, `set_size`, `set_parent`, `set_transient`,
`suggest_title`, `show`, `hide`.

Verified by `./build.sh --gui` — **19 checks, all passing** — which renders the panel into
an offscreen framebuffer and reads the pixels back: walnut cheeks are warm, the faceplate
is neutral graphite, its gradient runs light to dark, every engraved line is a dark groove
with a lit lower lip, no pixel is left undrawn, and 5 create/destroy cycles survive. It
also writes `build/panel.png` so the result can be looked at, not just asserted about.

Notes worth carrying forward:

- **nanovg's Odin port defaults to its GL3 backend** (`#version 150 core`), so the context
  must be a 3.2 core profile. A legacy profile silently fails to compile the shaders. On
  an M3 Max macOS reports the context as `4.1 Metal - 89.4` — OpenGL routed through Metal.
- **`vendor:OpenGL` is a loader with no platform linkage**, so entry points are resolved by
  name from `OpenGL.framework` at runtime (`src/gui/gl_loader.odin`).
- **A `foreign import` with no `foreign` block emits no link flag.** Importing AppKit and
  OpenGL that way looked like linkage but was not; `otool -L` shows only Cocoa, which is
  what actually provides the NSOpenGL* classes.
- **The context has no drawable until the view is in a window**, so nanovg is created
  lazily on the first render after `set_parent` rather than in `create`.

**Phase 6 — Widgets and binding. ✅ DONE.** The panel is live: knobs, buttons, two-position
toggles, a rotary selector, both LED ladders and the transfer window, all drawn in nanovg
from the coordinates in `design/panel.html`. Dragging a knob changes the audio; the host
records it as automation.

- **Mouse events need a subclassed NSView.** A plain one delivers nothing, and Odin cannot
  declare an Objective-C class at compile time, so `src/gui/input.odin` builds one at
  runtime with `objc_allocateClassPair` and stores a `^Gui` in an indexed ivar. Overriding
  `isFlipped` to true puts the origin at the top left, which is the coordinate space the
  design already uses. `acceptsFirstMouse:` matters too, or the first click into an
  unfocused plugin window is swallowed activating it.
- **Edits cross to the audio thread through an SPSC ring** (`plugin/ui_queue.odin`), drained
  in `process` and `flush`, applied, then echoed on `out_events` wrapped in
  `PARAM_GESTURE_BEGIN`/`END` so a drag is recorded as one gesture rather than hundreds of
  loose values. The GUI never writes DSP state.
- **`request_flush` is not optional.** With the transport stopped a host may not call
  `process` at all, so without asking for a flush, moving a knob would do nothing.
- **Values come back through an atomic mirror.** f64 has no atomic intrinsic, so the bits
  travel as u64 — exact, since it is a copy rather than arithmetic.
- **The transfer window samples the DSP's own gain computer**, so it cannot show a curve
  the audio is not applying.
- **Fonts are loaded from the system** (Arial Narrow Bold, Monaco). nanovg uses
  stb_truetype, which cannot open a `.ttc` collection without a face offset — so
  `Helvetica.ttc` is not usable and the `.ttf` files in `Supplemental/` are. A shipping
  build should embed a licensed face instead of depending on the host machine.

Interaction: drag a knob vertically, shift for fine, double-click to reset. Buttons,
toggles and the selector advance on press.

**Post-Phase-6 fix, found in DAW testing.** Controls changed the host's parameters but the
panel never moved. The drawing was correct — a guicheck that renders twice with different
values confirmed 3042 pixels differ — so the fault was the repaint trigger: the host was
not ticking `clap.timer-support`. Repainting no longer depends on it. Every interaction
repaints directly, which is required regardless because a default-mode run-loop timer does
not fire while the mouse is being tracked, and a run-loop `NSTimer` covers idle metering,
standing down whenever host ticks are arriving.

Verified: validator **21/16 passed/0 failed/0 warnings**, **27** DSP tests, **33** offline
audio checks, **4** plugin tests covering the ring buffer's ordering, wrap-around and
full-queue behaviour, and **21** GUI checks — every control on the faceplate, every one
clickable, knob caps rendering, the curve drawn in amber, the layout covering all 20
parameters.

**Phase 7 — Visual feedback. ✅ DONE.** Three meters, the live operating point, and a
scrolling gain-reduction history.

- **Input meter added**, so the bay now reads IN / GR / OUT — the classic trio. Input is
  measured *after* the trim, because that is the level the threshold compares against and
  therefore the x axis of the transfer window. The dBFS scale moved right of all three
  ladders: between GR and OUT it looked like it belonged to gain reduction, which counts a
  different quantity over a different range.
- **Meter ballistics are now buffer-independent.** They rise instantly and fall at a fixed
  dB per second. The previous version decayed a fixed amount per `process` call, so the
  same plugin metered roughly eight times faster at a 64-sample buffer than at 512.
- **Live operating point** on the transfer curve. Its y is the *measured* output, not the
  curve's value at that input, so while the envelope is still moving the dot rides off the
  curve — attack and release made visible.
- **Gain-reduction history**: a strip chart in the header spanning the ENVELOPE and TRANSFER
  bays, its bezel landing on those boundaries. 0 dB at the top with reduction hanging
  downward, newest sample at the right. Sampled on the timer tick rather than in `render`,
  or a drag — which repaints far more often than the timer fires — would make it lurch.

**Post-Phase-7 fix.** The operating point wavered around the curve instead of tracking it.
Its x came from the input meter and its y from `input − gain reduction`: two separate
meters with different ballistics (20 vs 36 dB/s), one a block peak and the other an
instantaneous gain, so the pair never described a single point on the curve. Both
coordinates now derive from the input level, with y taken from the same gain computer that
draws the line — the dot is on the curve by construction, which guicheck asserts by
sampling the exact computed position.

Verified: validator **21/16 passed/0 failed/0 warnings**, **27** DSP tests, **4** plugin
tests, **33** offline audio checks and **25** GUI checks, including that reduction fills
downward from the top, that the space below the trace stays clear, and that the input
ladder renders.

**Phase 8 — Polish.** Presets (`clap.preset-load`), `clap.remote-controls` for hardware
surfaces, param modulation, GUI resize. (Code signing and packaging for distribution are
deliberately deferred until the plugin has had time in real sessions.)

**Post-review correctness batch. ✅ DONE.** A full code review found four latent defects
the validator could never reach, all now fixed and locked in with new offline checks:

- **Degraded ports** (`process_block`): a host may express a disconnected input as a
  missing port array, a nil `data32`, or a zero-channel port. The first two previously
  read out of bounds or left the output buffer untouched — and an untouched output
  *repeats stale audio*. All degraded shapes now write silence, and output channels
  beyond the input's are zeroed.
- **Meters initialised to 0 dBFS**: the atomic meter slots decode zero bits as 0.0 dB,
  so a fresh insert showed a phantom near-full-scale reading decaying at 20 dB/s for
  half a minute. They are now published as `SILENCE_DB` at create and at activate.
- **State load ignored the latency path**: loading a session whose lookahead disagreed
  with the latched latency changed nothing and announced nothing. It now goes through
  the same `latency.changed` + restart request as an edit, guarded by a new `activated`
  flag so an inactive load stays silent (the value latches at the next `activate`).
- **GUI edits echoed unclamped**: `drain_ui` sent the raw ring value to `out_events`
  while applying the clamped one. The host now records what the DSP actually applied.

Also from the review, a deliberate seam widening for the planned 3-band crossover
version: `sync_dsp` and the GR meter now iterate `band_count` rather than touching
`bands[0]` directly, so growing the slice cannot leave band 0 special-cased. The
parameter table stays flat on purpose — per-band parameter pages get their own id
scheme when they arrive, and the `(id, value)` state format already tolerates it.

Verified: validator **21 tests, 16 passed, 0 failed, 0 warnings**; `odin test src/dsp`
**27** and `odin test src/plugin` **4**, all passing; `./build.sh --offline` **42
checks, all passing** (new: meters start at silence, three degraded-port shapes, state
round trip with latency announcement); `./build.sh --gui` **34 checks, all passing**.

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
