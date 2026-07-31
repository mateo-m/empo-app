# Save states

## Status

Research only. Nothing here is implemented. This doc records what "save states" can and
cannot mean for Empo, the prior art, and the recommended design, so the feature can be
picked up without redoing the investigation.

## What players mean by "save states"

In console emulators (NES, SNES, GBA), a save state is a byte-exact snapshot of the whole
machine at a single frame: copy the emulated RAM and every chip register to a file, and
loading it resumes the game at that exact instant. It works because a console is a small,
fixed machine — the emulator's entire fake hardware lives in a few hundred kilobytes of
memory with a known layout.

Players ask for two different things under this name:

1. **Frame-exact snapshots** - freeze mid-battle, mid-animation, anywhere, and resume
   exactly there. This is the console-emulator feature.
2. **Save anywhere** - stop losing progress between the game's own save points. This is
   what most requests actually need.

## Why console-style snapshots don't map to Empo

Empo is not an emulator. mkxp-z re-implements the RGSS engine and runs the game's real
Ruby scripts on a real Ruby interpreter. At any instant, "the game's state" is scattered
across:

- The active Ruby VM's heap: arbitrary object graphs, closures, fibers, threads — no
  fixed layout, different per Ruby version (1.8 / 1.9 / 3.1).
- C++ engine objects: sprites, bitmaps, viewports, tilemaps, audio streams.
- GPU state: textures, framebuffers, the GL context.
- Open file handles and stream positions.

There is no single block of memory to photograph, and a Ruby heap cannot be `memcpy`'d
and reloaded. This is why neither desktop mkxp-z nor JoiPlay has ever shipped save
states.

## Prior art: the libretro port's wasm2c sandbox

One project has genuinely solved frame-exact snapshots for RGSS:
[mkxp-z PR #255](https://github.com/mkxp-z/mkxp-z/pull/255) (white-axe, open since
June 2025) ports mkxp-z to libretro/RetroArch with real, deterministic save states. The
trick is to turn mkxp-z back into a console:

- Ruby and the script-side engine state are compiled to WebAssembly (`wasm32-wasip1`),
  then converted back to plain C with `wasm2c`.
- A WASM sandbox keeps its entire stack and heap in one flat linear-memory array — the
  same shape as a console's RAM. Serializing that array *is* the save state.
- On top of the memory image, the port snapshots WASI file-descriptor state and the PRNG,
  and unwinds/rewinds the Ruby call stack so states can be taken mid-transition.
- Bitmaps are split into 64x64 tiles; only modified tiles are serialized, and unmodified
  ones reload from the game's asset files, keeping states small.

Why Empo cannot just adopt it today:

- It replaces the native multi-Ruby architecture (`docs/multi-ruby.md`). The sandbox work
  targets modern Ruby; there is no Ruby 1.8 story, which Empo needs for RGSS1-era games.
- The sandbox supports no external libraries, so the `win32_wrap.rb` shims and native
  Win32 DLL emulation are out.
- A WASM sandbox pays an interpreter-shaped performance tax that matters more on mobile.
- The PR is unmerged and still moving.

One point in its favor for the long term: `wasm2c` output is ahead-of-time-compiled C,
so it does not hit the iOS no-JIT wall. If the PR merges upstream, a sandboxed backend
could become an *optional* mode for compatible games — but that is a second engine
backend, not a feature on the current one.

## The pragmatic design: RGSS-level save-anywhere

RPG Maker games already know how to save themselves: they `Marshal.dump` a known set of
globals (`$game_system`, `$game_switches`, `$game_variables`, `$game_map`,
`$game_player`, ...) to a slot file. That machinery is pure Ruby, and Empo controls the
Ruby VM via the preload-script mechanism (`scripts/preload/`). The design:

1. **Preload hook.** A preload script exposes one `empo_quick_save(path)` entry point,
   with a per-generation implementation behind it: RGSS1's `Scene_Save#write_save_data`
   logic, RGSS2's `Scene_File` equivalent, RGSS3's `DataManager.save_game`, and Pokémon
   Essentials' `SaveData` / `pbSave`. Detection can reuse the engine-version dispatch the
   app already performs at import.
2. **Frame-boundary execution.** The engine already freezes cleanly between frames for
   pause (`GraphicsPrivate::checkPause()`, see `docs/pause-resume.md`). The bridge gains
   a "run this Ruby hook at the next frame boundary" request; quick save runs there, on
   the engine thread, at a point where scripts are quiescent inside `Graphics.update`.
3. **Empo-owned slots.** Quick saves write to an Empo-owned path inside the game's
   sandbox directory, never to the game's numbered slots. Loading goes through the game's
   own load path pointed at that file.
4. **Autosave.** The same hook fires automatically on manual pause and on background
   pause, piggybacking on the existing pause flow.

### Semantics and caveats

- **Resumes on the map, not frame-exact.** Loading an RGSS save always re-enters
  `Scene_Map`. A quick save taken mid-battle or inside a menu restores to the map state
  behind it. Mid-*event* state largely survives, because the map interpreter is marshaled
  with the save (inside `$game_system` on XP, inside `$game_map` on VX/Ace).
- **Bypasses save gating by design.** Games lock save points via
  `$game_system.save_disabled`; a quick save ignores it. That is the feature, but it can
  break sequence-sensitive games — worth a per-game opt-out.
- **Custom scripts can fail to marshal.** A game whose modified globals hold unmarshalable
  objects (procs, bitmaps) will raise on quick save. Any game that saves at all already
  exercises this path, so the risk is confined to games with broken or heavily replaced
  save systems. Failures must be caught and surfaced, not fatal.
- **Games that replace the save system** (common in Essentials forks) may need the hook
  to prefer the game's own top-level save method when one is detectable.
- **Multi-session side effect.** Reliable autosave-on-exit softens the single-game-per-
  session limitation (`docs/multi-session.md`): losing the process no longer means losing
  progress since the last save point.

## Comparison

| Approach                        | Fidelity                  | Fits current engine | Cost                            |
| ------------------------------- | ------------------------- | ------------------- | ------------------------------- |
| Console-style memory snapshot   | Frame-exact               | No — no flat memory | Impossible as-is                |
| wasm2c sandbox (libretro PR)    | Frame-exact deterministic | No — new backend    | Re-architecture; no 1.8, no DLLs |
| RGSS-level save-anywhere        | Map-level, event state kept | Yes               | Preload hook + bridge + UI      |

## Recommendation

Ship RGSS-level quick save / autosave. It slots into the existing pause machinery and
preload-script system, works across all three Ruby versions, and covers what players
actually ask for. Track mkxp-z PR #255; revisit a sandboxed backend only if it merges
upstream and a compatible-game subset justifies a second backend.

## Sources

- [mkxp-z PR #255 - Libretro support](https://github.com/mkxp-z/mkxp-z/pull/255)
  (architecture and savestate details from the PR discussion)
- [libretro core info for mkxp-z](https://github.com/libretro/libretro-core-info/blob/master/mkxp-z_libretro.info)
  (`savestate = "true"`, `savestate_features = "deterministic"`)
- [mkxp-z upstream](https://github.com/mkxp-z/mkxp-z)
- [libretro docs: mkxp-z core](https://docs.libretro.com/library/mkxp-z/)
