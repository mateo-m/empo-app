# Multi-Session Game Compatibility

## Context

See `sdl-ruby-workarounds.md` for the foundational architecture (persistent SDL, persistent Ruby VM, session loop). This document covers the **game-level compatibility problems** that arise when running multiple RPG Maker games in sequence within a single process - and the fixes for each.

**Why this is hard:** Android emulators (JoiPlay) sidestep this entirely by calling `Process.killProcess()` after each game. iOS can't kill its own process, so we have to clean up the Ruby VM state manually between sessions. No version of CRuby supports `ruby_cleanup()` followed by `ruby_init()` - the VM is designed for single-use. Some workarounds (like `rb_gc_stack_start` patching and string-based constant names) are Ruby 1.8-specific, but the core problem and most game-level bugs apply to any Ruby version.

**Test matrix:** All fixes were validated with: Z→Z, U→U, U→Z→U→Z (where Z = Pokemon Z, U = Pokemon Uranium).

---

## Session Cleanup Sequence

At the end of each game session, before running the next game, the following cleanup runs in `mriBindingExecute()` (`binding-mri.cpp`):

1. **Update `rb_gc_stack_start`** - Point Ruby 1.8's GC stack scanner at the current thread's stack frame
2. **Pre-create `MkxpNullMouse` instance** - Must happen before step 3 removes `Game_Mouse` class
3. **Remove game-defined constants** - Diff `Object.constants` against a baseline captured after `mriBindingInit()`. Remove anything the game added. Uses `rb_funcall(rb_cObject, rb_intern("remove_const"), ...)` via C API
4. **Remove Input singleton methods** - Games add singleton methods to `Input` (e.g., Pokemon Essentials). These must be cleaned. `Graphics` singleton methods are NOT removed - doing so corrupts viewport state
5. **Clear game globals** - `$mouse` gets the `MkxpNullMouse` shim (see Bug 6). All other game globals are set to `nil`
6. **Force `rb_gc()`** - Collect stale RGSS objects from the previous session
7. **`mriBindingInit()`** - Re-register all native RGSS classes and methods (Sprite, Window, Viewport, etc.)
8. **Preload scripts run** - `platform_compat.rb` re-applies monkey patches (must happen every session, see Bug 5)
9. **Game scripts run** - New game starts fresh

### Baseline Constant Capture

The baseline is captured once, after the first `mriBindingInit()` but before any preload or game scripts. This gives us the "clean" set of constants that should persist across sessions. Anything not in the baseline was defined by a game and must be removed.

The capture uses the C API (`rb_funcall(rb_cObject, rb_intern("constants"), 0)`) and stores constant names in a `std::set<std::string>`. Ruby 1.8's `Object.constants` returns **strings**, not symbols - using `SYM2ID()` on them crashes (see Bug 10).

---

## Bug Fixes

### Bug 1: Viewport Doesn't Fill Screen on Second Session

**Symptom:** Game renders in a small rectangle instead of fullscreen on session 2+.

**Root cause:** `SDL_SetWindowSize()` is called between sessions in `main.cpp` to resize the persistent window for the new game's configured resolution. On iOS, this sets a logical size smaller than the physical screen, and the viewport never recovers.

**Fix:** Guard the `SDL_SetWindowSize` call with `#if !TARGET_OS_IPHONE` in `main.cpp`. On iOS the window is always fullscreen; the call is unnecessary.

---

### Bug 2: Infinite Ruby Recursion (Dir.chdir)

**Symptom:** Stack overflow on session 2. `Dir.chdir` calls itself infinitely.

**Root cause:** `platform_compat.rb` aliases `Dir.chdir` to wrap it with nil-safety. On session 2, the preload runs again and re-aliases - but now the "original" method IS the wrapped version, creating a recursive loop.

**Fix:** Guard the alias with `unless method_defined?(:_mkxp_orig_chdir)`.

```ruby
class << Dir
  unless method_defined?(:_mkxp_orig_chdir)
    alias_method :_mkxp_orig_chdir, :chdir
  end
  def chdir(dir = nil, &block)
    return _mkxp_orig_chdir(&block) if dir.nil?
    _mkxp_orig_chdir(dir, &block)
  end
end
```

---

### Bug 3: Superclass Mismatch TypeError

**Symptom:** `TypeError: superclass mismatch for class X` on session 2.

**Root cause:** RGSS silently allows reopening a class with a different superclass (Ruby 1.8 normally raises TypeError). Game A defines `class Foo < Bar`; constant cleanup removes `Foo`; game B (or same game replayed) defines `class Foo < Baz`. The leftover internal class structure conflicts.

**Fix:** In the script eval loop (`binding-mri.cpp`), catch `TypeError` matching "superclass mismatch for class (\w+)". Extract the class name, call `remove_const` on it, and retry the script eval. Up to 64 retries per script section to handle cascading conflicts.

---

### Bug 4: LoadError / NoMethodError / SyntaxError from Win32 DLLs

**Symptom:** Games crash trying to `require 'Win32API'` extensions or call methods from native DLLs that don't exist on iOS.

**Root cause:** RPG Maker games reference Windows DLLs (`System32.dll`, etc.) that obviously don't exist on iOS.

**Fix (binding-mri.cpp, iOS only):**

- **LoadError**: Skip entirely (log and continue to next script)
- **SyntaxError**: Skip entirely (some encrypted archives produce these)
- **NoMethodError**: Skip ONLY when the receiver is `Module` or `Class` (missing DLL-provided methods). Do NOT skip when receiver is `NilClass` or `FalseClass` - those are real game logic bugs that need to surface

---

### Bug 5: Disposed RGSS Objects Crash Mouse Input

**Symptom:** `RGSSError: disposed sprite` crash in Pokemon Essentials' `pokemonLoadPanel` during gameplay.

**Root cause:** Game code accesses properties of disposed RGSS objects. `disposed?` returns false but the native C++ object has been freed.

**Fix (`platform_compat.rb`):** Monkey-patch property accessors on `Sprite`, `Window`, `Viewport`, `Plane`, and `Tilemap` to rescue `RGSSError` and return safe defaults (0 for numeric, false for boolean, "" for string).

**Critical detail:** These patches must re-apply **every session**. `mriBindingInit()` re-registers native methods on session 2+, overwriting our Ruby wrappers. Therefore, the `platform_compat.rb` preload does NOT use `next if method_defined?` guards for these patches - they intentionally re-wrap every time.

---

### Bug 6: Cross-Session `$mouse` Contamination

**Symptom:** Session 2 crashes with `NoMethodError` on `$mouse` - the variable holds a `Game_Mouse` instance whose class no longer exists.

**Root cause:** Game A defines `Game_Mouse` and sets `$mouse = Game_Mouse.new`. Constant cleanup removes the `Game_Mouse` class, but `$mouse` still references the orphaned instance. Setting `$mouse = nil` doesn't work either - Ruby 1.8's `defined?($mouse)` returns `"global-variable"` even after assigning nil, so games that guard with `if defined?($mouse)` still try to use it.

**Fix:** Create a `MkxpNullMouse` shim class that absorbs all method calls:

```ruby
class MkxpNullMouse
  def method_missing(*) false end
  def respond_to_missing?(*) true end
  def disposed?() true end
  def x() 0 end
  def y() 0 end
end
```

The instance is pre-created **before** constant cleanup (step 2 in the cleanup sequence), then assigned to `$mouse` during global clearing (step 5). Games that check `$mouse.x` or `$mouse.update` get harmless return values instead of crashes.

---

### Bug 7: Disposable Intrusive List Corruption

**Symptom:** SIGSEGV in `Graphics::update()` on session 2, accessing freed memory through the disposable linked list.

**Root cause:** Each RGSS object (Sprite, Window, etc.) registers itself in `Graphics`' intrusive linked list via `Disposable`. When Ruby's GC eventually collects objects from the **previous** session, their `~Disposable()` destructor follows stale `prev`/`next` pointers - which now point into the **new** session's list, corrupting it.

**Fix:**

- Added `bool detached` flag to `Disposable` class (`disposable.h`)
- `Graphics::detachAllDisposables()` walks the list after session ends, sets `detached = true` on each node, and nulls their link pointers
- `~Disposable()` checks `detached` and skips `remDisposable()` if true
- Same fix applied to `Scene::~Scene()` for `SceneElement` link pointers (`scene.cpp`)

---

### Bug 8: "X is not a module" / "X is not a class" TypeError

**Symptom:** `TypeError: PBTerrain is not a module` on session 2.

**Root cause:** Different games (or different sessions of the same game after partial cleanup) define the same name as a class vs. a module.

**Fix:** Extended the TypeError retry loop (Bug 3's fix) to also match `"(\w+) is not a module"` and `"(\w+) is not a class"` patterns. Same `remove_const` + retry logic.

---

### Bug 9: `system('Uranium')` Causes SIGKILL on iOS

**Symptom:** App is killed by the OS (SIGKILL / `__stack_chk_fail`) on Uranium's second session.

**Root cause:** Pokemon Uranium has a "Hard Reset" script (85 bytes) that checks `$game_exists` and calls `system('Uranium')` + `exit` to relaunch itself as a new process. On session 2, `$game_exists` persists as `true` (from the previous session), so `system()` calls `fork()+exec()` - **forbidden on iOS**. The OS kills the app immediately.

**Debugging journey:** This was the hardest bug to find. We ruled out SyntaxError in script 253, GC corruption, and thread-local storage issues. The breakthrough came from logging the actual script content of every evaluated section and discovering the 85-byte script calling `system()`.

**Fix (`platform_compat.rb`):**

- Neutralize `Kernel#system`, `Kernel#exec`, `Kernel#fork`, `Kernel#spawn` to be no-ops
- Clear `$game_exists = nil` in preload so the hard-reset path is never reached

```ruby
module Kernel
  def system(*args) nil end
  def exec(*args) raise SystemExit end
  def fork(*args) nil end
  def spawn(*args) nil end
  module_function :system, :exec, :fork, :spawn
end
```

---

### Bug 10: Ruby 1.8 Constants Are Strings, Not Symbols

**Symptom:** SIGSEGV in constant cleanup code on any session 2+.

**Root cause:** The cleanup code iterated `Object.constants` and used `rb_id2name(SYM2ID(cname))` to get each constant's name. But Ruby 1.8's `Object.constants` returns an array of **strings**, not symbols. Calling `SYM2ID()` on a string causes an immediate SIGSEGV.

**Fix:** Use `RSTRING_PTR(cname)` instead of `rb_id2name(SYM2ID(cname))`.

---

## Files Modified

| File                              | Changes                                                                                             |
| --------------------------------- | --------------------------------------------------------------------------------------------------- |
| `binding-mri.cpp`                 | Session cleanup, TypeError retry loop, error skip, baseline capture, debug logging, crash handler   |
| `main.cpp`                        | Persistent RGSS thread with semaphore loop, `detachAllDisposables()` call, SDL_SetWindowSize guard  |
| `graphics.h` / `graphics.cpp`     | `detachAllDisposables()` method                                                                     |
| `scene.cpp`                       | `Scene::~Scene()` nulls SceneElement link pointers                                                  |
| `disposable.h`                    | `bool detached` flag, guarded destructor                                                            |
| `app_bridge.h` / `app_bridge.cpp` | `mkxp_debugLog()`, `mkxp_setDebugLogPath()`, `mkxp_getDebugLogPath()`                               |
| `platform_compat.rb`              | system/exec/fork neutralization, disposed object patches, MkxpNullMouse, Dir.chdir guard, env stubs |
| `win32_wrap.rb`                   | `kappatalize()` strips non-alphanumeric characters                                                  |
