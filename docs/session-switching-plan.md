# Plan: game-session switching without killing Empo

## Goal

The user quits game A, lands in the library, taps game B (or game A again),
and plays it — in the same process, without force-closing Empo, **an unlimited
number of times per launch**. Today this is impossible: the engine is
single-shot (`EngineHost::runSession` runs once, then the app shows the
"close from the app switcher" alert). See `docs/multi-session.md` for why the
previous cross-session cleanup approach was abandoned.

## Decisions (from plan review)

- **Unlimited switches per launch is the requirement.** Any architecture where
  the number of playable sessions is bounded by a build-time count of Ruby
  copies ("1 island = 1 session") is rejected — that includes embedding K
  renamed copies of an island. One island binary per Ruby version, unlimited
  instances at runtime.
- **Same-game restart is in scope** and must work. Under fresh-instance-per-
  session it needs no special path: a restart is just a new session that
  happens to point at the same game. This also gives `Reset` (F12 /
  `Graphics.reset`-style restarts) a real implementation for free.
- **App Review conservatism is not a constraint** at this stage. Techniques
  like dlopening a copied, signed dylib from the app container are on the
  table.
- **The old cross-session cleanup machinery gets deleted**, not kept as a
  fallback: `pokemon_session_reset.rb`, the session-2+ paths in
  `binding-mri.cpp`, and the constant/singleton-baseline plumbing. Fresh
  instances make them structurally unnecessary, and they encode the approach
  we've concluded is unsound.
- Historical note: the earlier multi-session failures were not island-
  isolation failures. The blockers were app-size growth per island and the
  bounded session count — both addressed by this plan's single-island,
  many-instances design.
- **Stage 3 (container reset) is a ship requirement, not optional R&D.**
  The finished feature must leave memory clean after/before each session;
  the `os_proc_available_memory` soft gate is temporary scaffolding that
  exists only while copy-and-load can leak retired images, and it retires
  with Stage 3.

## Ground truth (what constrains any design)

1. **iOS forbids self-termination and process spawning.** No `fork`/`exec`, no
   `Process.killProcess()` trick (JoiPlay's Android escape hatch), and App
   Store guideline 2.5.1 forbids programmatic exit. One process, forever.
2. **CRuby cannot be re-initialized in place.** `ruby_cleanup` + a second
   `ruby_init` against the same set of VM globals crashes. Upstream has never
   supported it, on any of our three versions (1.8.8, 1.9.3, 3.1.3).
3. **In-place VM state cleanup between games already failed.** Constant-baseline
   diffing, singleton-method scrubbing, disposable detachment — shipped, then
   reverted, because the surface (arbitrary monkey-patches across arbitrary
   game pairs) is unbounded. We are not going back down that road.
4. **We already have three isolated Ruby VMs in the binary.** The multi-Ruby
   build symbol-islands each version's libruby + binding into a `merged.o`
   (`mkxp18/19/31-merged.o`) whose only export is
   `mkxp_get_script_binding_NN()`. Every global — VM state, symbol table,
   parser state — is private to its island.
5. **The non-Ruby engine is already session-shaped.** Window, EGL/ANGLE context,
   and the OpenAL device/context persist across a session; `SharedState`
   init/fini runs per session; `EventThread` is constructed per session. The
   pause/resume machinery proves the host↔engine lifecycle plumbing works.

The core insight from (2)+(3): **never try to clean or reuse a dirty VM. Give
every session a factory-fresh VM instance and throw the old one away.** The
plan manufactures unlimited fresh VM instances inside one iOS process, from a
single shipped island per Ruby version.

---

## Architecture: one island per version, unlimited instances

Each Ruby version's island becomes a standalone dylib (embedded framework,
e.g. `RubyIsland31.framework`) instead of a statically-linked `merged.o`. The
islanding work already done (`ld -r -unexported_symbols_list`) maps directly
onto a dylib's export list; a dylib is the natural form of a symbol island
(two-level namespace, and — critically — its own `__DATA`/`__bss` segments,
cleanly separable from the rest of the process).

A new engine-side **instance manager** replaces the static
`mkxp_get_script_binding_NN()` dispatch: per session it produces a
`RubyInstance { dlHandle, ScriptBinding *, rubyVersion, generation }`, and at
session end it retires the instance. Freshness comes from one of three
mechanisms, which are *stages of hardening*, not alternatives to choose
between forever:

### Stage 1 — dlclose-unload (target mechanism)

`dlopen` the island at session start; at session end quiesce Ruby (stop VM
threads, `ruby_cleanup`-lite to close FDs and free what it can), restore the
process sigaction table, `dlclose`. If dyld genuinely unloads the image, the
next `dlopen` of the same path yields fresh statics → unlimited sessions, zero
accumulation.

Unloadability requirements (all within our control):

- No ObjC/Swift content in the image (true — pure C/C++).
- No `__thread` TLS: Ruby 3.1 uses `RB_THREAD_LOCAL_SPECIFIER` for
  `ruby_current_ec`; build with the pthread_getspecific fallback (we control
  Ruby patches). Audit 1.8/1.9 (expected clean — pre-TLS codebases).
- C++ statics register destructors via `__cxa_atexit`, which is dso-scoped and
  handled by dyld on unload. Plain `atexit` from Ruby gets patched out (we
  never process-exit through Ruby anyway).
- Verify unload at runtime with a canary (e.g. `dladdr` on the retired entry
  point). Instrument, don't assume.

### Stage 2 — copy-and-load (fallback if unload fails)

If `dlclose` turns out to be a no-op for our image shape: copy the bundled,
signed island dylib to a unique path in the app container, `dlopen` the copy
(distinct path → distinct image → fresh statics), and `unlink` the file
immediately after load — the mapping survives, so there is no disk
accumulation either. Code signatures are content-hashed and path-independent;
same-Team library validation passes. Unlimited sessions; the cost is that
retired images stay mapped and their VM memory accumulates (see Memory).

Stages 1 and 2 compose: always attempt `dlclose`; if the canary says the image
is still resident, route the next session through copy-and-load. Either way
the user gets a fresh VM — the difference is only whether the old one's memory
is reclaimed.

### Stage 3 — the disposable VM container (deterministic endgame)

The "fully resettable container" that `docs/multi-session.md` names as future
work, made concrete. One image per version, mapped once, reused forever, with
*flat* memory across sessions:

1. **Segment snapshot/restore.** After `dlopen` but before the first
   `ruby_init`, snapshot the island's writable segments (`__DATA`,
   `__DATA_DIRTY`, zero-fill `__bss`) — they are exactly the island's globals.
   At session end, quiesce all island threads, then memcpy the segments back
   to pristine. The next `ruby_init` runs as if it were the first in the
   process.
2. **Arena allocator interposition.** Route the island's `malloc`/`calloc`/
   `realloc`/`free` (and the GC's page allocator) to a per-session arena via
   symbol interposition at the dylib boundary. Session end → destroy the arena
   → every byte the VM ever allocated is returned O(1). No leaks, and no
   dangling pointers either: the restored segments hold pre-init values, so
   nothing references the freed arena.
3. **Process-state hygiene.** Save/restore sigaction around the session; skip
   Ruby's `atexit` registration; accept the bounded pthread-key leak (a few
   keys per session against a 512 limit — hundreds of sessions per launch) or
   track-and-delete.

**Why this succeeds where constant-diffing failed:** it operates at the image
level and needs *zero knowledge of Ruby semantics*. It cannot miss a leaked
class, a monkey-patch, or a version-specific data structure, because it resets
every byte of VM state indiscriminately, identically on 1.8, 1.9, and 3.1.
The hard parts are thread quiescence (VM/timer threads must be provably dead
before restore) and completeness of the allocator interposition (any
allocation that escapes the arena is a leak; any island pointer retained by
the host across the reset is a bug — the `ScriptBinding` vtable handoff is the
only sanctioned crossing).

## Memory across sessions

A retired VM instance that is truly unloaded (Stage 1) or container-reset
(Stage 3) costs nothing. A retired instance under Stage 2 keeps its GC heap
resident — potentially 100–300 MB for a big PE fork — and iOS kills
over-budget apps without warning (jetsam), which to the user looks like a
crash mid-game, i.e. *worse* than today's honest alert.

Posture, in order:

- Reclaim aggressively at session end (`ruby_cleanup`-lite, GC, page return)
  regardless of stage; measure per-session RSS delta in the diagnostics
  harness.
- While Stage 2 is the active mechanism, gate the "start another game"
  affordance on `os_proc_available_memory()`: below a device-calibrated
  watermark, degrade to the honest alert instead of letting jetsam kill the
  app mid-play. (Open question: exact watermark policy — pending.)
- Stage 3 removes the problem class entirely; the watermark then becomes a
  should-never-fire assertion.

---

## Rejected approaches (and why)

| Approach | Verdict |
| --- | --- |
| K embedded island copies ("1 island = 1 session") | Rejected by decision: bounded session count, app size grows per session. |
| In-place Ruby state cleanup (constant diffing, method scrubbing) | Already shipped and reverted; unbounded per-game surface. Structural dead end. |
| `fork()` per session | No `exec` on iOS, ObjC runtime is not fork-safe, guideline 2.5.1 territory. Non-starter. |
| Auxiliary process via app extension | Extensions cannot render a fullscreen interactive game; GPU-over-IPC is fantasy-land. |
| ruby.wasm / Wasm interpreter per session | Perfect isolation, but no 1.8/1.9 Wasm target exists, the whole C++ binding layer would need a Wasm bridge, and interpreter-speed Wasm (no JIT on iOS) is too slow for PE forks. |
| Patch CRuby for true re-`ruby_init` | Upstream never achieved it; requires deep surgery × 3 versions. Stage 3 gets the same result with no interpreter knowledge. |

## Phasing, validation, instrumentation

- **Phase A — session loop foundation.** `main()` becomes `init()` → loop
  `{ waitForGamePath → runSession }` → `shutdown()`; framebuffer clear and
  game-path handshake re-arm between sessions; per-session sigaction
  save/restore; delete the old cleanup machinery; re-enable the parked
  `returnToLibrary()` quit paths behind a feature flag; same-game restart and
  `Reset` wired through "end session, start new session, same path". Until
  Phase B lands, second-session-on-a-dirty-island stays behind the existing
  alert — a temporary state, not the destination.
- **Phase B — dylib islands + instance manager.** Dylib-ify the 3.1 island
  first (biggest user value); in-app diagnostics harness reporting
  dlclose-unload success (canary), dyld image count, per-session RSS delta;
  Stage 1 + Stage 2 composition wired; roll to 1.9/1.8. **Unlimited switching
  ships here.**
- **Phase C — container reset.** Stage 3 prototype behind the same harness;
  soak test 50+ sessions cycling a corpus of real games (A→B→A→C…), asserting
  flat RSS and zero cross-session Ruby symptoms; retire the memory watermark
  to an assertion.
- Keep `MKXP_RUBY_UNSET` legacy direct-link path working for desktop/test
  builds throughout (dylib-ification is iOS-only build plumbing).
- On-device matrix throughout: 1.8→3.1, 3.1→1.8, 1.9→3.1, same-game restart,
  each interleaved with pause/resume and background flows.

## Files that move (first wave)

- `mkxp-z-apple-mobile/src/main.cpp` — session loop restoration.
- `mkxp-z-apple-mobile/src/app_bridge.{h,cpp}` — capability/instance API,
  per-session re-arm of the game-path handshake.
- `mkxp-z-apple-mobile/src/binding.h` — dispatcher becomes the instance
  manager boundary (dlopen handles instead of static entry points, Phase B).
- `mkxp-z-apple-mobile/binding/binding-mri.cpp` — delete session-2+ cleanup
  paths; single-shot comments become per-instance lifecycle docs.
- `mkxp-z-apple-mobile/scripts/preload/pokemon_session_reset.rb` — delete.
- `ios/Dependencies/common.make` + `multiruby/wrapper.cpp` — merged.o →
  framework targets (Phase B).
- `ios/Empo/src/App/AppState.swift`, `GameLibraryView.swift`,
  `PlayerMoreSheet.swift`, `GameContextMenu.swift`, `RootView.swift` —
  re-enable quit paths behind the flag, capability-driven UX.
