# CLAUDE.md — multicomp

A CLAP-format compressor plugin written in Odin. macOS arm64 only for now.

Target: a full-featured **single-band** compressor, with the DSP structured so bands
are a slice that can grow to multiband later (hence the project name) without a rewrite.

## Environment

| Thing | Where | Version |
|---|---|---|
| Odin compiler | `/Users/gmb/code/odin/dist/odin` (on PATH) | `dev-2026-08-nightly:902106f` |
| CLAP C headers | `/Users/gmb/code/github/free-audio/clap` | 1.2.10 (`a47f6ba`) |
| Odin CLAP bindings | `./clap-odin` (nested git repo) | tracks CLAP 1.2.10 |
| `clap-validator` | `/Users/gmb/code/bin/clap-validator` | official test suite |
| `clap-info` | `/Users/gmb/code/bin/clap-info` | descriptor/extension dump |
| Platform | macOS (darwin) arm64 | |

`odinfmt`/`ols` are **not** installed — format by hand to the conventions below.

Version control: **jj**, colocated with a git repo for GitHub interop. Use `jj` commands
(`jj status`, `jj log`, `jj commit`), not `git add`/`git commit` — jj snapshots the working
copy automatically, so there is nothing to stage. `clap-odin/` is a separate nested git
repo; the verified-good binding state there is its working tree, not its `HEAD`.

## Layout

```
multicomp/
  CLAUDE.md          this file — the single source of truth
  AGENTS.md          a symlink to CLAUDE.md, so both conventions find the same doc
  PLAN.md            implementation roadmap and status
  build.sh           build, bundle, validate, install
  build/             output (gitignored)
  src/
    plugin/          package plugin — built as the dylib
      entry.odin       descriptor, factory, exported clap_entry
      plugin.odin      Multicomp struct, lifecycle, process()
      params.odin      parameter table + clap.params
      state.odin       versioned state serialisation
      extensions.odin  audio-ports, latency, tail, extension dispatch
      gui.odin         clap.gui + timer-support + the bridge implementation
      ui_queue.odin    SPSC ring: GUI edits in, atomic mirror out
      ui_queue_test.odin  @(test) procs, run with `odin test src/plugin`
    dsp/             package dsp — pure DSP, no CLAP types, unit-testable
      db.odin          dB conversions, one_pole_coeff
      gain_computer.odin  static curve with quadratic soft knee
      envelope.odin    Level_Detector (peak/RMS/hybrid) + Envelope_Follower, auto-release
      biquad.odin      RBJ biquad, transposed direct form II
      delay.odin       lookahead delay, caller-supplied storage
      smoother.odin    one-pole parameter smoothing
      stereo.odin      lossless mid-side encode/decode
      band.odin        Compressor_Band — per-channel state, stereo link, multiband seam
      dsp_test.odin    @(test) procs, run with `odin test src/dsp`
    gui/             package gui — Cocoa view + GL context + nanovg, no CLAP types
      cocoa.odin       NSOpenGLContext/PixelFormat/NSEvent bindings, NSView helpers
      gl_loader.odin   resolves GL entry points from OpenGL.framework at runtime
      gui.odin         view/context lifecycle, render loop
      bridge.odin      the vtable plugin/ fills in — keeps CLAP out of this package
      layout.odin      control table: where every widget sits, and hit testing
      widgets.odin     knob, button, toggle, selector, meter ladders
      draw.odin        header, bay legends, transfer window, meters
      input.odin       runtime NSView subclass, mouse handling, drag
      font.odin        system font loading with fallbacks
      panel.odin       chassis: cheeks, faceplate, engraved divisions
  design/
    panel.html       the approved faceplate design — the GUI spec, 1180x460
  tools/
    offline/         offline CLAP host for measuring real audio (./build.sh --offline)
    guicheck/        renders the faceplate headlessly and checks pixels (--gui)
  clap-odin/         CLAP bindings — treat as a vendored dependency
    *.odin           package clap  — core API + factories
    ext/*.odin       package ext   — stable extensions
    ext/draft/*.odin package draft — draft extensions
```

## Importing the bindings

`clap-odin/ext/*.odin` uses a **relative** import that assumes the folder is named
`clap-odin` and sits one level below its parent:

```odin
import clap "../../clap-odin"      // in ext/
import clap "../../../clap-odin"   // in ext/draft/
```

Do not rename or move `clap-odin/` without fixing every one of those. From our own
code, import via a collection rather than relative paths:

```sh
odin build src -collection:proj=/Users/gmb/code/foesoft/multicomp
```

```odin
import clap "proj:clap-odin"
import ext  "proj:clap-odin/ext"
```

## Build, package, verify

Typecheck the bindings (all three must be silent):

```bash
odin check clap-odin -no-entry-point && odin check clap-odin/ext -no-entry-point && odin check clap-odin/ext/draft -no-entry-point
```

Run the test suites:

```bash
odin test src/dsp
```

```bash
odin test src/plugin -collection:proj=/Users/gmb/code/foesoft/multicomp
```

`src/dsp` needs no collection because it has no CLAP dependency, which is the point of
keeping it that way.

Build, bundle, validate and install all go through `build.sh`:

```bash
./build.sh --validate
```

`--offline` runs [tools/offline](tools/offline) — a small offline CLAP host that loads the
built plugin, pushes real audio through it and measures the result. It checks things the
validator does not: that the gain reduction matches the static curve at known settings,
that bypass is transparent, that the impulse delay equals the reported latency, that
degraded input ports (missing, nil, zero-channel) produce silence rather than stale audio,
that meters start at silence, and that a state round trip restores values and announces a
latency change when a loaded lookahead disagrees with the latched one. Use it
whenever DSP behaviour changes. It resolves parameters **by name**, so reordering
`Param_Id` cannot silently invalidate the checks.

`--gui` runs [tools/guicheck](tools/guicheck), which makes the GL context current with no
view attached, renders the faceplate into a framebuffer object and reads the pixels back.
clap-validator never opens a window, so without this the whole Cocoa/GL/nanovg chain would
be unproven until it worked or crashed inside a DAW. It also writes `build/panel.png`.

`--install` symlinks the bundle into `~/Library/Audio/Plug-Ins/CLAP/` (a symlink, so
rebuilds are picked up without reinstalling). `--debug` swaps `-o:speed` for `-debug`.
Flags combine. The script fails the build if the `_clap_entry` symbol is missing.

Under the hood it runs:

```bash
odin build src/plugin -collection:proj=<repo root> -build-mode:shared -out:build/multicomp.dylib
```

A CLAP on macOS is a bundle, not a bare dylib. Required shape:

```
MultiComp.clap/Contents/
  Info.plist        CFBundleExecutable=MultiComp, CFBundlePackageType=BNDL
  PkgInfo           the 8 bytes "BNDL????"
  MacOS/MultiComp   the dylib, renamed, no extension
```

Validation is the gate — run it before claiming anything works. Current status:
**21 tests, 16 passed, 0 failed, 5 skipped, 0 warnings**, plus **28** DSP tests, **5**
plugin tests, **58** offline audio checks and **38** GUI checks. The 5 skips are note-port and preset-discovery tests, correctly
skipped for an audio effect that has neither yet.

One trap: validating a *freshly written* dylib trips the validator's 100 ms `scan-time`
check, because the very first `dlopen` of a new file pays for dyld mapping plus macOS's
one-time signature assessment — 130–430 ms, none of it our code. Warm, this plugin scans
in ~1 ms. `build.sh` does a throwaway `clap-info` load first to absorb that. If you run
`clap-validator` by hand right after a build and see a scan-time warning, run it twice.

## Binding fidelity — verified, do not re-litigate casually

The bindings were checked **mechanically** against the 1.2.10 headers, not by eye:

- **137/137 structs** match exactly on size, alignment, field count, and every field offset
  (clang `-fdump-record-layouts-complete` vs Odin `reflect.struct_fields_zipped`).
- **228/228 function-pointer fields** match on name, parameter count, and return-vs-void.
- **171 enum members**, zero value mismatches against compiler-evaluated C constants.
- **93/93 CLAP string constants** (extension IDs, feature strings, port types) match.
- Nothing missing, nothing extra.

Conclusion: these are sound, ABI-correct bindings. Treat a crash as a bug in *our* code
before suspecting the bindings.

Known intentional deviations from the C headers — leave them alone:

- `CLAP_PROJECT_LOCATION_INSTUMENT_TRACK` (typo upstream) is bound as `INSTRUMENT_TRACK`,
  with an alias under the upstream spelling.
- C prefixes are dropped: `clap_event_note` → `clap.Event_Note`, `CLAP_EXT_PARAMS` →
  `ext.EXT_PARAMS`, `CLAP_PORT_STEREO` → `ext.AUDIO_PORT_STEREO`.
- Flag-typed struct fields are plain `u32`/`u64`, not `bit_set`, while the flag *values*
  live in Odin `enum`s. So you write `u32(ext.Param_Info_Flag.AUTOMATABLE)`. Casting an
  Odin enum to its backing type yields the **value** (`1<<5`), not the ordinal.
- A few binding-side names are non-idiomatic (`clap.Clap_Id` stutters, `BEAT_TIME`/`SEC_TIME`
  are types in SCREAMING_CASE, `clap.CLAP_VERSION`). Don't churn them mid-project; if they
  ever get fixed it should be one deliberate pass across the whole bindings repo.

To re-verify after a CLAP version bump, regenerate the layout/signature/enum dumps and diff
them; the approach is described in PLAN.md.

## Odin style — follow this

Standard Odin conventions, which the bindings already follow:

- **Types**: `Ada_Case` — `Compressor_State`, `Param_Id`
- **Procedures**: `snake_case` — `db_to_linear`, `process_block`
- **Constants**: `SCREAMING_SNAKE_CASE` — `MAX_BLOCK_SIZE`
- **Variables, struct fields, package names**: `snake_case` / lowercase
- **Indentation**: tabs
- `::` declares compile-time constants; `:=` declares variables
- Prefer `for i in 0 ..< n` over C-style loops; use `defer` for cleanup
- Return `(value, ok)` rather than sentinel values
- Keep packages flat — one directory is one package

## CLAP + Odin gotchas

These are the things that actually bite. Learned from a validated smoke-test build.

**The `context` in `proc "c"` callbacks.** Every CLAP callback is `proc "c"` and therefore
has *no* Odin context. Anything needing one (`new`, `free`, `fmt.*`, most of `core:`) is a
compile error until you write `context = runtime.default_context()`. This is a feature, not
a nuisance: the compiler mechanically stops you from allocating on the audio thread.

- Main-thread callbacks (`get_extension`, `get_info`, `create_plugin`, `destroy`): set the
  context, it is cheap and does not allocate.
- **`process()` and anything it calls: never set the context.** Let the compiler enforce
  realtime safety. Use `proc "contextless"` for DSP helpers so they are callable from both.

**Recovering your plugin struct.** Embed `clap.Plugin` as the *first* field and store a
self-pointer in `plugin_data`:

```odin
Multicomp :: struct {
	plugin: clap.Plugin,   // must stay first
	host:   ^clap.Host,
	// ...
}

self := (^Multicomp)(plugin.plugin_data)
```

**Exporting the entry point.** `@(export)` on a package-level variable named `clap_entry`
produces the `_clap_entry` data symbol hosts look for. Verify with
`nm -gU build/multicomp.dylib | grep clap_entry`.

**Descriptor `features`** is a NULL-terminated `[^]cstring`. Assign it inside
`clap_entry.init` (`descriptor.features = raw_data(features[:])`) rather than in a global
initializer.

**Comparing IDs.** `string(id) == ext.EXT_PARAMS` — the `cstring`→`string` conversion does
a `strlen`, so keep it on the main thread, never in `process`.

**Sample-accurate events.** Walk `process.in_events` and split the block at each event's
`.time` rather than applying all events at block start. The validator's
`param-*`/`state-reproducibility-*` tests care about this.

**Threading.** CLAP annotates every callback: `[main-thread]`, `[audio-thread]`,
`[thread-safe]`. Honour them — the bindings preserve those comments from the C headers.
Parameter values reach the DSP only through events (`process` and `flush`), never by the
GUI writing shared state directly.

## Adding a parameter

`PARAMS` in [src/plugin/params.odin](src/plugin/params.odin) is a `[Param_Id]Param`
enumerated array — indexed by the enum, so lookup is O(1) and an entry can never end up
under the wrong id. To add one:

1. Add a variant to `Param_Id`. **Append it at the end**, and never renumber existing ones.
2. Add the matching `.Your_Param = { ... }` entry to `PARAMS`.
3. If it is a `.Choice`, add its `enum` and its parallel `_CHOICES` string slice.

That is the whole change — `count`, `get_info`, `get_value`, state save/load and the
defaults all read from the table.

State is written as explicit `(id, value)` pairs, not a positional array, so this is safe:
an id an older build does not recognise is skipped on load, and a parameter missing from
an older session keeps its default. Bump `STATE_VERSION` only when the *encoding* changes,
not when parameters are added.

Flag sets are pre-composed: `FLAGS_CONTINUOUS` (automatable; `MODULATABLE` returns when
`PARAM_MOD` is actually handled), `FLAGS_SWITCH` (automatable + stepped), `FLAGS_CHOICE`
(+ `IS_ENUM`). Stepped values are rounded to integers in `clamp_param`, because hosts and
our choice indexing have to agree on what the value means.

**A parameter whose behaviour is not implemented yet must carry `NOT_IMPLEMENTED`**
(which is `CLAP_PARAM_IS_HIDDEN` — CLAP documents that flag as exactly "should not be shown
to the user, because it is currently not used"). Otherwise a host's generic UI offers a
control that silently does nothing, which reads as a bug. Drop the flag in the same change
that makes the parameter work. `./build.sh --offline` prints the visible/hidden split.

**Audio ports**: two inputs (main + sidechain) and one output, stereo by default. CLAP
has no dedicated sidechain flag — the sidechain is identified by *not* carrying
`IS_MAIN`. Hosts often leave it disconnected, so `process` must fall back to the main
input rather than assuming `audio_inputs_count > 1`. `clap.audio-ports-config` offers a
mono layout (one-channel main in/out, stereo sidechain) that hosts may select while the
plugin is deactivated; `process` is channel-count agnostic, so mono needs no DSP path of
its own.

**Input trim reaches the detector only when the detector is the main signal.** Internally
they are the same signal, so the trim has to apply or the threshold stops meaning what the
input meter shows. An *external* sidechain arrives at whatever level the host routed to
it, and trimming the signal being compressed must not change how hard that source ducks
it — there is deliberately no sidechain trim control, because a DAW already has several.
The test is the source actually in use, not the parameter: External with nothing patched
in falls back to the main input, and the trim applies again. Guarded by
`./build.sh --offline`.

**Defaults must leave the plugin transparent.** Inserting it and touching nothing may not
change the signal. Ratio therefore defaults to 1:1, where the gain computer returns its
input unchanged at every level and the applied gain is exactly 1.0 — threshold and knee
become irrelevant. `./build.sh --offline` asserts this at five input levels.

Note that `clap-info` does not render the `IS_ENUM` flag at all — its flag vocabulary
predates it. Absence there is not evidence the flag is missing; check the raw
`Param_Info.flags` bits instead (`IS_ENUM` is bit 16, `0x10000`).

## Working agreements

- `clap-validator validate` must pass with **0 failures and 0 warnings**, `odin test src/dsp`
  must be fully green, and `./build.sh --offline --gui` must report all checks passed,
  before any change is called done. Report the actual counts.
- Latency must stay constant while active — CLAP requires it. Anything that changes latency
  latches at `activate` and asks the host for a restart from `on_main_thread`; it must not
  be automatable. A state load that changes lookahead goes through the same announce path
  (guarded by `self.activated`), not a silent swap.
- **`values` has exactly one writer.** `process`, `flush` and `activate` write it, and CLAP
  guarantees those never overlap. `state.load` is `[main-thread]` with no `!active`
  restriction, so it must *not* write it — it fills `staged`, publishes the mirror, and
  sets `staged_pending`; the next of those three calls swaps the set in whole via
  `apply_staged`. That is what stops a preset being seen half-applied for a block.
  Main-thread readers (`params.get_value`, `state.save`) read `mirror`, which is atomic and
  — because `publish_values` runs before process/flush return — never lags behind `values`.
- `process` must survive degraded ports — a missing input array, a nil `data32`, or a
  zero-channel port all produce silence, and output channels beyond the input's are
  zeroed. An untouched output buffer repeats stale audio, which reads as a hang.
- No allocation, locks, file or console I/O in `process()` or below. `src/dsp/` is
  `proc "contextless"` throughout, which makes this a compile error rather than a dropout.
- DSP in `src/dsp/` stays free of CLAP types so it can be tested with `odin test`. If a
  compressor change needs a CLAP type, it belongs in `plugin/`. `src/gui/` follows the same
  rule: `plugin/gui.odin` translates clap.gui calls into plain entry points.
- The GUI is **main-thread only**. Parameter edits must reach the DSP as events, never by
  the GUI writing shared state — they go through the SPSC ring in `plugin/ui_queue.odin`,
  get applied in `process`/`flush`, and are echoed on `out_events` so the host records
  them. Value pushes stop short of full so gesture events always fit (a dropped
  `GESTURE_END` leaves a host gesture open forever), and `drain_ui` coalesces a run of
  edits to one control into its newest member. Always call `request_flush` after
  queueing, or edits stall on a stopped transport.
- Adding a parameter means adding it to **both** `PARAMS` and `gui.CONTROLS`; the ids in
  `gui/layout.odin` mirror `Param_Id`. `./build.sh --gui` asserts the counts match.
- Meters must rise instantly and fall at a fixed rate **per second**, not per `process`
  call — otherwise the same plugin meters at different speeds depending on the host's
  buffer size.
- **Never rely on `clap.timer-support` alone for repainting.** It is optional, and a host
  may register a timer and then never tick it, which leaves a correct panel frozen on its
  first frame. `gui/` keeps a run-loop `NSTimer` fallback that stands down while host ticks
  are arriving, and every interaction repaints directly — a default-mode timer does not
  fire at all while the mouse is being tracked.
- Tests live in the same package (`dsp_test.odin`). Confirmed cheap: `@(test)` procs and
  the `core:testing` import add ~1 KB to the shipped dylib.
- Enums the DSP switches on (`Detector_Mode`, `Topology_Mode`) are defined in `dsp/` and
  referenced from `plugin/`. Do not redeclare them — the display strings would drift from
  the behaviour.
- Don't "fix" the binding naming conventions in passing — see the deviations list above.
