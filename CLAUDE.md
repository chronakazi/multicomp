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

Repo state: `multicomp/` itself is **not** a git repository. `clap-odin/` is, and it
currently has uncommitted modifications to most binding files. The verified-good
binding state is the working tree, not `HEAD`.

## Layout

```
multicomp/
  CLAUDE.md          this file
  PLAN.md            implementation roadmap and status
  build.sh           build, bundle, validate, install
  main.odin          vestigial empty placeholder — unused, safe to delete
  build/             output (gitignored)
  src/
    plugin/          package plugin — built as the dylib
      entry.odin       descriptor, factory, exported clap_entry
      plugin.odin      Multicomp struct, lifecycle, process()
      params.odin      parameter table + clap.params
      extensions.odin  audio-ports, state, latency, extension dispatch
    dsp/             package dsp — pure DSP, no CLAP types, unit-testable
    gui/             (Phase 5) nanovg drawing + Cocoa view embedding
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

Build, bundle, validate and install all go through `build.sh`:

```bash
./build.sh --validate
```

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
**21 tests, 15 passed, 0 failed, 6 skipped, 0 warnings.** The 6 skips are note-port
tests, correctly skipped for an audio effect.

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

## Working agreements

- `clap-validator validate` must pass with **0 failures and 0 warnings** before any change
  is called done. Report the actual counts.
- No allocation, locks, file or console I/O in `process()` or below.
- DSP in `src/dsp/` stays free of CLAP types so it can be tested with `odin test`.
- Don't "fix" the binding naming conventions in passing — see the deviations list above.
