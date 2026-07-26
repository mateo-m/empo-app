# Plan: game-session switching without killing Empo

## Goal

The user quits game A, lands in the library, taps game B, and plays it — in the
same process, without force-closing Empo. Today this is impossible: the engine
is single-shot (`EngineHost::runSession` runs once, then the app shows the
"close from the app switcher" alert). See `docs/multi-session.md` for why the
previous cross-session cleanup approach was abandoned.

## Ground truth (what constrains any design)

1. **iOS forbids self-termination and process spawning.** No `fork`/`exec`, no
   `Process.killProcess()` trick (JoiPlay's Android escape hatch), and App
   Store guideline 2.5.1 forbids programmatic exit. One process, forever.
2. **CRuby cannot be re-initialized in place.** `ruby_cleanup` +  a second
   `ruby_init` in the same set of VM globals crashes. Upstream has never
   supported it, on any of our three versions (1.8.8, 1.9.3, 3.1.3).
3. **In-place VM state cleanup between games already failed.** Constant-baseline
   diffing, singleton-method scrubbing, disposable detachment — shipped, then
   reverted, because the surface (arbitrary monkey-patches across arbitrary
   game pairs) is unbounded. We are not going back down that road.
4. **We already have three isolated Ruby VMs in the binary.** The multi-Ruby
   build symbol-islands each version's libruby + binding into a `merged.o`
   (`mkxp18/19/31-merged.o`) whose only export is
   `mkxp_get_script_binding_NN()`. Every global — VM state, symbol table,
   parser state — is private to its island. `ruby_init` in the 1.8 island has
   never touched the 3.1 island's globals.
5. **The non-Ruby engine is already session-shaped.** Window, EGL/ANGLE context,
   and the OpenAL device/context persist across a session; `SharedState`
   init/fini runs per session; `EventThread` is constructed per session. The
   pause/resume machinery proves the host↔engine lifecycle plumbing works.

The core insight from (2)+(3): **never try to clean or reuse a dirty VM. Give
every session a factory-fresh VM instance and throw the old one away.** The
entire plan is about manufacturing fresh VM instances inside one iOS process,
in three tiers of increasing ambition. Each tier ships value on its own.

---

## Tier 0 — Re-enable the session loop; fresh-island switching

**What:** Restore multi-session at the host/engine level, and allow switching
whenever the next game's Ruby island is still virgin.

- Engine: `main()` becomes `init()` → loop `{ waitForGamePath → runSession }`
  → `shutdown()`. After a clean session end, clear the framebuffer, re-arm
  `mkxp_waitForGamePath()`, and idle. (Most of this existed before the
  single-shot regression; `runSession` is already parameterized per session.)
- New bridge API: `mkxp_sessionCapability(MKXPRubyVersion)` →
  `FRESH | DIRTY | UNAVAILABLE`. An island that has run `ruby_init` once is
  DIRTY for the rest of the process.
- iOS: re-enable the parked quit paths (`returnToLibrary()` callers) behind a
  feature flag. The library queries the capability API per game card: a game
  whose island is fresh gets normal "play"; a game whose island is dirty gets
  the existing "close from app switcher" alert (now the *exception*, not the
  rule).

**What this buys immediately:** up to three games per launch — one per Ruby
version — with **zero new VM technology**. Quit a 1.8 vintage game, start a
3.1 PE fork: the 3.1 island's `ruby_init` runs for the first time on pristine
globals. No superclass mismatch is possible because no state is shared.

**Open risk to retire first:** `docs/multi-session.md` says the old failures
were "especially mixed-version sessions". If those failures were Ruby-state
bugs, islands make them structurally impossible; if they were engine-side
(SharedState / GL / audio / bindings), they will bite Tier 0 immediately and
must be fixed here. Needs the old repro corpus (see grilling questions).

## Tier 1 — Ruby islands become dlopen-able instances

**What:** Turn each `mkxpNN-merged.o` from a statically-linked island into a
standalone dylib (embedded framework, e.g. `RubyIsland31.framework`) with the
same single-export surface, and mint fresh VM instances by loading fresh
images.

The islanding work is already done — the `ld -r -unexported_symbols_list` step
that hides Ruby internals maps directly onto a dylib's export list, and a
dylib is the *natural* form of a symbol island (two-level namespace, own
`__DATA`/`__bss` segments).

Session start: `dlopen` a pristine image of the needed version, `dlsym` the
entry point, run the session. Session end: quiesce Ruby (stop VM threads,
`ruby_cleanup`-lite to close FDs and free what it can), restore the process
sigaction table (Ruby installs handlers; our fatal-report handlers re-arm),
then discard the instance. Freshness strategies, in order of preference:

- **1a. `dlclose` genuinely unloads.** Requires the image to be unloadable: no
  ObjC/Swift content (true — pure C/C++), no `__thread` TLS (Ruby 3.1 uses
  `RB_THREAD_LOCAL_SPECIFIER` for `ruby_current_ec`; build with the
  pthread_getspecific fallback — we control Ruby patches), C++ statics use
  `__cxa_atexit` which is dso-scoped and handled by dyld on unload. Verify
  unload at runtime with a canary. If it works → **unlimited sessions**, next
  `dlopen` of the same path gives fresh statics.
- **1b. K embedded copies per version.** dyld treats distinct paths as distinct
  images with distinct statics. Embed `RubyIsland31_1..K.framework`; each copy
  is one fresh session. Fully App-Store-boring. Cost: binary size (measure the
  per-island size first; K is a tunable per version — e.g. K=3 for 3.1, K=1
  for 1.9).
- **1c. Copy-and-load.** Copy the bundled, signed dylib to a unique path in the
  app container and `dlopen` the copy. Code signatures are content-hashed and
  path-independent; same-Team library validation passes. Unlimited sessions,
  no binary bloat, but unusual enough to need an App Review risk call
  (it is *not* downloaded code — 2.5.2 — but reviewers surprise us).

**Memory posture:** a dirty, un-unloadable instance leaks its GC heap
(potentially 100–300 MB for a big PE fork). Before abandoning an instance, run
GC + `ruby_cleanup` to return what we can; track per-session RSS; gate the
"start another game" affordance on `os_proc_available_memory()` so we degrade
to the honest alert instead of letting jetsam kill the app mid-play.

## Tier 2 — The disposable VM container (deterministic, unlimited)

**What:** the "fully resettable container" that `docs/multi-session.md` names
as future work, made concrete. One dylib per version, reused forever, without
relying on `dlclose`:

1. **Segment snapshot/restore.** After `dlopen` but before the first
   `ruby_init`, snapshot the island dylib's writable segments (`__DATA`,
   `__DATA_DIRTY`, zero-fill `__bss`) — they are exactly the island's globals,
   cleanly separable because the island is its own Mach-O image. At session
   end, quiesce all island threads, then memcpy the segments back to pristine.
   The next `ruby_init` runs as if it were the first in the process.
2. **Arena allocator interposition.** Route the island's `malloc`/`calloc`/
   `realloc`/`free` (and the GC's page allocator) to a per-session arena via
   symbol interposition at the dylib boundary. Session end → destroy the arena
   → every byte the VM ever allocated is returned O(1). No leaks, and no
   dangling pointers either: the restored segments hold pre-init values, so
   nothing references the freed arena.
3. **Process-state hygiene.** Save/restore sigaction around the session; patch
   Ruby to skip `atexit` registration (we never exit through it); accept the
   bounded pthread-key leak (a few keys per session against a 512 limit —
   hundreds of sessions per launch) or track-and-delete.

**Why this succeeds where constant-diffing failed:** it operates at the image
level and needs *zero knowledge of Ruby semantics*. It cannot miss a leaked
class, a monkey-patch, or a version-specific data structure, because it resets
every byte of VM state indiscriminately. It also works identically on 1.8,
1.9, and 3.1. The hard parts are thread quiescence (VM/timer threads must be
provably dead before restore) and completeness of the allocator interposition
(any allocation that escapes the arena is a leak; any island pointer retained
by the host across the reset is a bug — the `ScriptBinding` vtable handoff is
the only sanctioned crossing).

---

## Rejected approaches (and why)

| Approach | Verdict |
| --- | --- |
| In-place Ruby state cleanup (constant diffing, method scrubbing) | Already shipped and reverted; unbounded per-game surface. Structural dead end. |
| `fork()` per session | No `exec` on iOS, ObjC runtime is not fork-safe, guideline 2.5.1 territory. Non-starter. |
| Auxiliary process via app extension | Extensions cannot render a fullscreen interactive game; GPU-over-IPC is fantasy-land. |
| ruby.wasm / Wasm interpreter per session | Perfect isolation, but no 1.8/1.9 Wasm target exists, the whole C++ binding layer would need a Wasm bridge, and interpreter-speed Wasm (no JIT on iOS) is too slow for PE forks. |
| Patch CRuby for true re-`ruby_init` | Upstream never achieved it; requires deep surgery × 3 versions. Tier 2 gets the same result with no interpreter knowledge. |

## Phasing, validation, instrumentation

- **Phase 0** (Tier 0): engine session loop + capability API + Swift flag
  flip. On-device matrix: 1.8→3.1, 3.1→1.8, 1.9→3.1, each direction, with the
  existing pause/resume and background flows interleaved.
- **Phase 1** (Tier 1): dylib-ify the 3.1 island first (biggest user value);
  in-app diagnostics harness that reports dlclose-unload success (canary),
  dyld image count, per-session RSS delta. Decide 1a/1b/1c from device data,
  then roll to 1.9/1.8.
- **Phase 2** (Tier 2): container prototype behind the same harness; soak test
  50+ sessions cycling a corpus of real games (A→B→A→C…), asserting flat RSS
  and zero cross-session Ruby symptoms.
- Keep `MKXP_RUBY_UNSET` legacy direct-link path working for desktop/test
  builds throughout (dylib-ification is iOS-only build plumbing).

## Files that move (first wave)

- `mkxp-z-apple-mobile/src/main.cpp` — session loop restoration.
- `mkxp-z-apple-mobile/src/app_bridge.{h,cpp}` — capability API, per-session
  re-arm of game-path handshake.
- `mkxp-z-apple-mobile/src/binding.h` — dispatcher grows instance awareness
  (dlopen handles instead of static entry points, Tier 1).
- `ios/Dependencies/common.make` + `multiruby/wrapper.cpp` — merged.o →
  framework targets (Tier 1).
- `ios/Empo/src/App/AppState.swift`, `GameLibraryView.swift`,
  `PlayerMoreSheet.swift`, `GameContextMenu.swift`, `RootView.swift` —
  re-enable quit paths behind the flag, capability-driven UX.
