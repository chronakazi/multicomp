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
surfaces, param modulation (and re-adding `MODULATABLE` with it — the flag was dropped
in the polish batch because advertising modulation that `handle_event` ignores is a
silent no-op in hosts), GUI resize. (Code signing and packaging for distribution are
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
version: `sync_dsp` now iterates `band_count` rather than touching `bands[0]` directly,
so growing the slice cannot leave band 0 special-cased. The parameter table stays flat
on purpose — per-band parameter pages get their own id scheme when they arrive, and the
`(id, value)` state format already tolerates it.

Verified: validator **21 tests, 16 passed, 0 failed, 0 warnings**; `odin test src/dsp`
**27** and `odin test src/plugin` **4**, all passing; `./build.sh --offline` **42
checks, all passing** (new: meters start at silence, three degraded-port shapes, state
round trip with latency announcement); `./build.sh --gui` **35 checks, all passing**.

**Audio polish batch. ✅ DONE.** Four audible-quality fixes and one port feature:

- **Bypass crossfade.** Bypass was an instantaneous switch between the processed path
  and the latency-aligned dry path - a guaranteed click whenever the two levels differ
  (which, with any compression at all, is always). It is now a 20 ms crossfade through
  the smoother set, so it is sample-accurate in onset and click-free in transition. The
  offline harness measures the largest sample-to-sample jump across a mid-signal toggle:
  0.052 (the sine's own natural slope) vs the 0.257 a hard switch would produce.
- **Auto makeup and mix are smoothed.** Auto makeup is folded *into* the Makeup
  smoother's target (via a shared `curve_from_values` helper, replacing the separately
  cached `auto_makeup_db`), so automating the curve with auto makeup on ramps the
  compensation instead of stepping it. Mix gets its own smoother for the same reason.
- **GR metering is peak-per-block.** The meter previously read the envelope's final
  sample of the block, missing transients that attacked and recovered inside one buffer;
  it now tracks the deepest reduction applied anywhere in the block.
- **Mono port configuration** via `clap.audio-ports-config`: "Stereo" (default) and
  "Mono" (one-channel main in/out; the sidechain stays stereo). Selection is refused
  while active, per the spec. `process` needed no mono-specific path - the correctness
  batch's port hardening already made it channel-count agnostic, and the offline host
  proves the mono layout compresses to the same figure as stereo.

Also: `MODULATABLE` was dropped from `FLAGS_CONTINUOUS` - `handle_event` ignores
`PARAM_MOD`, and a modulatable-looking parameter that silently does nothing is exactly
the failure mode `NOT_IMPLEMENTED` discipline exists to prevent. Phase 8 re-adds the
flag together with the implementation.

Verified: validator **21 tests, 16 passed, 0 failed, 0 warnings**; `odin test src/dsp`
**27** and `odin test src/plugin` **4**, all passing; `./build.sh --offline` **50
checks, all passing** (new: bypass-transition click detector, config count/layout/
select/rescan, mono compression figure); `./build.sh --gui` **35 checks, all passing**.

**GUI/hygiene batch. ✅ DONE.** The remaining review items, all in the GUI<->audio seam:

- **The UI ring can no longer orphan a gesture.** Value pushes stop 8 slots short of
  full, so `GESTURE_BEGIN`/`END` always have somewhere to go - a dropped END previously
  left the host's automation gesture open forever. The full-queue test now locks the
  policy in.
- **Drag edits are coalesced at drain.** A run of values for one control collapses to
  its newest member before being applied and echoed - one automation point per block
  per control instead of one per mouse event, with no loss of feel. Covered by a new
  plugin test that captures the echoed event stream.
- **The mirror is only published on a successful push.** A dropped edit used to leave
  the knob showing a value the DSP never applied until the next edit landed.
- **The transfer curve no longer races the audio thread.** `bridge.curve` builds its
  gain computer from the atomic parameter mirror (via a `make_curve` helper shared with
  `sync_dsp`) instead of reading the band's computer mid-write.
- **Double-click reset is scoped to knobs.** On buttons/toggles/selectors a second
  click is just another press; previously it both advanced and reset the control.
- **`set_scale` answers honestly.** The panel is fixed-size, so it returns false rather
  than claiming success. Retina backing is unaffected - it is handled per frame from
  the view's `backingScaleFactor`.
- **The GL drawable follows the window.** A runtime `viewDidMoveToWindow` override
  (forwarding to NSView's implementation via `class_getMethodImplementation`) plus a
  per-frame backing-scale check in `render`, so moving between displays or displays of
  different density can no longer leave a stale drawable.

Also: the guicheck stub's transfer curve now calls the DSP's real gain computer instead
of a re-derived copy, and a stray spaces-for-tabs indentation slipped in `input.odin`
is fixed.

Evaluated and deliberately left as-is: the `fonts_ok` gate still skips all controls when
no system font loads (every draw call needs a font for labels; a half-labelled panel is
not better than a bare chassis), and `smoother_is_settled` stays as a tested utility
rather than becoming a micro-optimisation in the sample loop.

Verified: validator **21 tests, 16 passed, 0 failed, 0 warnings**; `odin test src/dsp`
**27** and `odin test src/plugin` **5** (new: drain coalescing), all passing;
`./build.sh --offline` **50 checks, all passing**; `./build.sh --gui` **35 checks, all
passing**.

**Review batch, with measurements. ✅ DONE.** A second full review, this time with both hot
paths benchmarked rather than reasoned about. Six items, in the order they were found:

- **A state load never republished the GUI mirror.** `reset_to_defaults` published the
  defaults and the entry loop then wrote `values` directly, so until the next `process`
  or `flush` the panel showed defaults while the DSP used the loaded preset. On a stopped
  transport that is indefinitely — load a preset, open the window, every knob is wrong.
  Nothing caught it because the offline harness read `params.get_value` (the audio
  thread's array) and guicheck drives a stub bridge; neither had ever read the mirror.
  A new `com.foesoft.multicomp.mirror` readback interface, sibling to the meter one,
  makes "what the panel would show" assertable. Confirmed to fail before the fix: the
  mirror read -18 (the default) where the state said -20.
- **`params.flush` dereferenced a nil event header.** `process` had always skipped holes
  in a sloppy host's event list; `flush` had the identical loop without the guard.
  Confirmed by reverting: a segfault, not a failed assertion.
- **`plugin.destroy` did not tear the GUI down.** A host is supposed to destroy the GUI
  first; if one does not, the run-loop `NSTimer` keeps firing `tick:` into a freed
  struct. Both paths now go through one idempotent `gui_teardown`.
- **The brushed texture cost more than the entire DSP.** Measured: a full repaint was
  1.68 ms, of which `draw_panel` was 0.88 ms, of which the striations were 0.80 ms —
  nanovg re-tessellating ~380 separate stroked hairlines every frame. As a tiled 3pt
  image it is 0.04 ms. Frame time 1.68 → **0.89 ms**, 10.1% → **5.3%** of a core at
  60 Hz; the chassis alone 0.88 → 0.13 ms. The two renders differ by at most **3/255**
  on any channel of any pixel, with the striations landing on the same coordinates.
  One trap on the way: nanovg's invalid image handle is `0`, not a negative, so the
  obvious `>= 0` guard would have drawn with a dead texture.
- **SC Listen monitored an undecoded mid-side signal.** In M/S the detector array is
  still encoded, so auditioning it put the mid in the left channel and the side in the
  right. It is decoded for monitoring only; the filter is linear, so what comes out is
  the filtered L/R exactly. Before the fix a hard-left source came back centred and
  6 dB down.
- **Input trim no longer feeds the external sidechain.** It is a main-path staging
  control, and an external source arrives at whatever level the DAW routed to it — so
  trimming the signal being compressed now moves the output by exactly that much and
  leaves the ducking depth alone. Fed to both, a +6 dB trim deepened the reduction by
  4.5 dB and moved the output by only 1.5. The *internal* detector still sees the trim,
  because there it is the same signal and the threshold has to keep meaning what the
  input meter says; so does the fallback when External is selected with nothing patched
  in, since the detector really is the main input in that case. No extra SC trim control
  — the DAW already has plenty of ways to set that level.
- **AGENTS.md is now a symlink to CLAUDE.md**, which is the single source of truth. It
  had been a byte-identical 346-line copy, which is a guaranteed drift.

Two numbers worth carrying forward, both measured rather than assumed:

- **The DSP costs 0.19% of one core** — 40 ns per stereo sample at 48 kHz for the whole
  chain. `math.pow(10, x)` is 2.6 ns and `log10` 6.4 ns on this hardware, so the instinct
  to strip transcendentals out of the sample loop would buy nothing. Leave `dsp/db.odin`
  alone.
- **The open GUI now costs ~5.3% of a core**, still ~28x the audio path. The remaining
  0.86 ms is `draw_controls`, and the repaint is unconditional: a dirty flag (any mirrored
  value moved, any meter above silence) would take idle cost to near zero. That is the
  next GUI optimisation, if one is wanted.

Verified: validator **21 tests, 16 passed, 0 failed, 5 skipped, 0 warnings**;
`odin test src/dsp` **27** and `odin test src/plugin` **5**, all passing;
`./build.sh --offline` **55 checks** (new: SC listen decodes M/S and keeps a hard-left
source hard left, input trim does not feed the external sidechain, state load republishes
the mirror, flush survives a hole in the event list) and `./build.sh --gui` **36 checks**
(new: brushed texture created), all passing.

Still open from the review, deliberately not taken in this batch:

- **`state.load` writes `values` from the main thread while `process` reads them**, so a
  preset load during playback can be seen half-applied for one block. Same class on the
  read side for `params.get_value` and `state.save`. Benign on arm64, where an aligned
  f64 does not tear, but the mirror exists precisely for this.
- **`frames_count == 0` drops every event in the block**, as does any event whose `.time`
  is past the end — the `for frame < frames_count` loop never runs.
- **The runtime Objective-C class is registered once per process and never disposed**, so
  a host that `dlclose`s and reloads the plugin gets a class whose method pointers are in
  an unmapped image.
- **`gui.attach` is not idempotent** — a second `set_parent` adds the subview twice.
- **Feedback topology has no stability test** at fast attack and high ratio.

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
