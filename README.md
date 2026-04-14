# mkxp-ios

An iOS port of [mkxp-z](https://github.com/mkxp-z/mkxp-z), which is itself a fork of [mkxp](https://github.com/Ancurio/mkxp). It lets you run RPG Maker XP games (RGSS1) on iPhones and iPads. Only Ruby 1.8 is bundled right now, so VX (RGSS2) and VX Ace (RGSS3) games are not currently supported.

## How it works

The engine (`mkxp-z/`) does all the heavy lifting: it reimplements the RGSS runtime that RPG Maker games expect, using SDL2 for windowing and input, OpenGL ES 2.0 for rendering, OpenAL for audio, and an embedded Ruby interpreter to run game scripts. The iOS-specific code (`ios/`) builds it as a native iOS app, adds a SwiftUI game library and touch controls overlay, and bundles all the dependencies as static libraries.

When the app launches, it presents a **game library** where you can browse imported games and import new ones (folders or `.zip` files) via the system document picker. Selecting a game hands its path to the engine, which loads the `.ini` file, `mkxp.json`, or `.rgssad` archive. A set of Ruby preload scripts run before the game's own scripts to patch over Windows-specific assumptions (Win32API calls, environment variables, etc.) so that games work without modification.

### Library UI

The library is built entirely in SwiftUI with a playful design: SF Rounded font, liquid glass buttons, a morphing import button that arcs between expanded (empty state) and collapsed (header) positions, and card-based game display with artwork thumbnails. Games can be imported from folders or `.zip` files, with real-time progress indicators (indeterminate for folders, determinate for zips). The app supports dark, light, and auto themes applied at the UIWindow level.

### Ruby 1.8

Most RPG Maker XP games were written against Ruby 1.8. mkxp-z normally ships with Ruby 3.1, but many older games break on it due to syntax and API changes. This port cross-compiles Ruby 1.8 (from [JoiPlay's ruby_1_8 branch](https://github.com/joiplay/ruby)) as a static library to maximize compatibility with RGSS1 games.

### Touch controls

A transparent UIKit overlay window sits on top of SDL's OpenGL rendering surface. It provides:

- A D-pad (bottom-left) for directional input
- Action buttons (A, B, Shift) on the bottom-right
- A toolbar with edit mode, keyboard toggle, reset, and hide buttons
- Edit mode where you can drag, resize, relabel, re-bind, or delete any button
- The ability to add new buttons mapped to arbitrary key presses

The overlay injects SDL keyboard events directly, so the engine sees them exactly as if they came from a hardware keyboard. The touch controls are self-contained in `ios/mkxp-ios/src/Player/` and do not require any engine modifications.

## Project structure

```
mkxp-ios/
  setup.sh                           # Run once after cloning (configures git hooks)
  .githooks/                         # Tracked git hooks
    post-commit                      # Regenerates GitInfo.generated.swift
  docs/                              # Architecture and design docs
  mkxp-z/                            # mkxp-z engine source (upstream + iOS patches)
    src/
      main.cpp                     # Entry point, FBO setup, OpenAL init
      eventthread.cpp              # SDL event loop (KEYUP fix)
      display/bitmap.cpp           # Font height fix, mega surface fallback
      display/graphics.cpp         # Rendering pipeline
      display/gl/                  # OpenGL ES 2.0 backend
      audio/                       # Audio subsystem (OpenAL + SDL_sound)
      ios_bridge.cpp               # C bridge for iOS <-> engine communication
    binding/                       # Ruby/RGSS bindings (MRI)
    shader/                        # GLSL shaders (embedded at compile time)
  ios/
    Dependencies/
      common.make                  # Shared dependency build rules
      iphonesimulator.make         # Simulator target (arm64)
      iphoneos.make                # Device target (arm64)
      build-iphonesimulator-arm64/ # Built libraries + headers (not in git)
      downloads/                   # Dependency source checkouts (not in git)
    mkxp-ios/
      project.yml                  # XcodeGen project spec
      Info.plist                   # App metadata
      src/
        mkxp-ios-Bridging-Header.h # Bridges C engine API to Swift
        systemImplIOS.mm           # iOS system functions (scaling factor)
        filesystemImplIOS.mm       # iOS filesystem (game root detection)
        App/                       # App lifecycle and root UI
          AppLoader.m              # +load bootstrap (creates UIWindow before main)
          AppWindow.swift          # UIWindow above SDL, theme observation
          AppState.swift           # @Observable state machine (library/loading/playing/quitting)
          EngineState.swift        # Engine runtime state (game rect, background pause)
          PauseManager.swift       # User-initiated pause/resume (snapshot, paused game)
          AppSettings.swift        # Persisted settings (theme, debug mode, log retention)
          RootView.swift           # Root SwiftUI view (SF Rounded, phase-based routing)
          GitInfo.generated.swift  # Auto-generated commit hash for version display
        Design/                    # Design system
          Theme.swift              # Color tokens (brand, surface, semantic), spacing, radii
          Primitives.swift         # Haptics, button styles, empty state, transitions
        Library/                   # Game library (import, browse, delete)
          GameLibraryView.swift    # Grid layout, morphing import button, liquid glass header
          GameCard.swift           # Game card component (artwork, title, import progress)
          GameEntry.swift          # Game data model (title, path, artwork, import state)
          GameLibrary.swift        # Game scanning, importing, deletion
          GameLoadingView.swift    # Loading screen (spinner while engine boots)
          GameInfoView.swift       # Game detail/info view
          GameSettingsView.swift   # Per-game settings (overrides)
          GameSettings.swift       # Per-game settings model
          GameMetadata.swift       # Game metadata extraction
          GameArtworkView.swift    # Artwork display component
          GameContextMenu.swift    # Context menu for game cards
          ImportButton.swift       # Morphing import button
          ImageSourcePicker.swift  # Image source selection for artwork
          ImageCache.swift         # In-memory image cache
          GameImportValidator.swift # Validates imported game structure
          ZipExtractor.swift       # Zip extraction with progress callback
          DocumentPickerView.swift # System document picker (UIDocumentPickerViewController)
        Settings/                  # App settings
          SettingsView.swift       # Theme picker, title position, debug toggles
          SettingsComponents.swift # Reusable toggle/picker components
        Player/                    # In-game overlay
          PlayerView.swift         # Game viewport + controls layout
          ControlsLayout.swift     # Portrait/landscape control positioning
          ControlsEditModifier.swift # Edit mode for repositioning controls
          DebugOverlayView.swift   # Debug info overlay
          KeyCatalog.swift         # Available key bindings catalog
          TouchControls.h          # Touch controls interface
          TouchControls.mm         # Touch controls implementation (D-pad, buttons, toolbar)
          TouchControlRepresentables.swift # UIKit-to-SwiftUI bridge
      shims/                       # Headers that stub out unavailable platform APIs
        al.h, alc.h, alext.h       # Redirect OpenAL includes to Apple's framework
        TouchBar.h                 # Stub for macOS Touch Bar API
        SettingsMenuController.h   # Stub for macOS settings menu
      Assets.bundle/
        Preload/                   # Ruby scripts loaded before game scripts
          ios_compat.rb            # Engine-level iOS patches (fork, env vars, Dir.chdir)
          pokemon_compat.rb        # Pokemon Essentials/fangame patches (disposed objects, $mouse)
          ruby_classic_wrap.rb     # Ruby 1.8 compatibility helpers
          win32_wrap.rb            # Win32API emulation layer (CC0, by Ancurio)
          mkxp_wrap.rb             # mkxp module compatibility
        Postload/                  # Ruby scripts loaded after game scripts, before Main
          pokemon_input.rb         # Pokemon Essentials Input redirect (native j-prefixed methods)
        Fonts/                     # Fallback fonts (Liberation Sans, WenQuanYi)
        Shaders/                   # GLSL vertex/fragment shaders
  demo/
    games/                         # Game folders go here (not in git)
```

## Building

### Requirements

- Xcode (with iOS 26+ SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Standard Unix build tools (`autoconf`, `automake`, `libtool`, `cmake`, `pkg-config`)
- An Apple developer account (free or paid) for code signing

### 0. Initial setup

After cloning the repo, run the setup script once:

```sh
./setup.sh
```

This configures git to use the tracked hooks in `.githooks/` (which keep the version display in sync with the latest commit) and generates the initial `GitInfo.generated.swift`.

### 1. Build dependencies

All third-party libraries are cross-compiled from source via Makefiles. For the iOS Simulator:

```sh
cd ios/Dependencies
make -f iphonesimulator.make deps-core
```

For a real device:

```sh
cd ios/Dependencies
make -f iphoneos.make deps-core
```

This downloads, configures, and builds all required libraries as static archives. It takes a while the first time.

Ruby 1.8 is built separately (see the `ruby_1_8` build notes). The resulting `libruby18-static.a` and `libruby18-ext.a` go into the dependency build directory's `lib/` folder, and headers go into `include/ruby18/`.

### 2. Generate the Xcode project

```sh
cd ios/mkxp-ios
xcodegen generate --spec project.yml --project .
```

### 3. Build the app

```sh
cd ios/mkxp-ios
xcodebuild -project mkxp-ios.xcodeproj \
  -target mkxp-ios \
  -sdk iphonesimulator \
  -arch arm64 \
  -configuration Debug \
  build
```

The output is at `ios/mkxp-ios/build/Debug-iphonesimulator/mkxp-z.app`.

For a device build, replace `-sdk iphonesimulator` with `-sdk iphoneos`.

### 4. Run on Simulator

```sh
# Find your simulator UDID
xcrun simctl list devices available | grep iPhone

# Install and launch
xcrun simctl install <UDID> ios/mkxp-ios/build/Debug-iphonesimulator/mkxp-z.app
xcrun simctl launch <UDID> com.mkxp.mkxp-ios
```

### 5. Add a game

Games are imported at runtime through the app's library UI. Tap the import button, select a game folder or `.zip` file from the system document picker, and the app copies it into its sandboxed `Documents/Games/` directory. No rebuild required.

For development, you can also copy game folders directly into the simulator's app container:

```sh
CONTAINER=$(xcrun simctl get_app_container <UDID> com.mkxp.mkxp-ios data)
cp -R /path/to/your/game "$CONTAINER/Documents/Games/"
```

### LSP / compile_commands.json

For IDE support (clangd, etc.), a `compile_commands.json` can be generated from the Xcode build. The key is to disable header maps (which clangd can't read) and inline the response files Xcode uses:

```sh
cd ios/mkxp-ios
xcodebuild -project mkxp-ios.xcodeproj \
  -target mkxp-ios -sdk iphonesimulator -arch arm64 \
  -configuration Debug clean build USE_HEADERMAP=NO \
  2>&1 > /tmp/build.log
```

Then parse the log to extract compile commands, inline any `@*.resp` file references, and strip `-ivfsstatcache` flags. The resulting file goes in the project root.

## Key engine changes from upstream mkxp-z

These are all generic fixes, not game-specific:

- **FBO 0 is not the screen on iOS.** SDL creates a non-zero framebuffer. The engine queries the actual screen FBO after `SDL_GL_MakeCurrent` and uses that instead of hardcoded 0.
- **Missing KEYUP handling.** The `SDL_KEYUP` case label was absent from the event thread's switch statement.
- **Font height calculation.** Some game fonts have broken `hhea` metrics. The engine uses `abs(ascent) + abs(descent)` instead of `TTF_FontHeight()`.
- **OpenAL context on main thread.** `alcMakeContextCurrent` must be called from the main thread on iOS.
- **Mega surface CPU fallback.** Bitmaps larger than `GL_MAX_TEXTURE_SIZE` (4096 on iOS) fall back to CPU-based rendering instead of crashing.
- **Win32API / GetAsyncKeyState.** A C-level `Input.asyncKeyState(vKey)` method reads directly from the event thread's key state array.
- **Ruby 1.8 RAPI clamping.** `RAPI_FULL` computes to 188 but all mkxp-z guards use `> 187`, so it is clamped to 187 to take the correct code paths.

## Dependencies

All dependencies are open-source and built from source as static libraries.

| Library                                                      | Version/Branch | License                        | Source       |
| ------------------------------------------------------------ | -------------- | ------------------------------ | ------------ |
| [SDL2](https://github.com/mkxp-z/SDL)                        | mkxp-z-2.28.1  | zlib                           | mkxp-z fork  |
| [SDL_image](https://github.com/mkxp-z/SDL_image)             | mkxp-z         | zlib                           | mkxp-z fork  |
| [SDL_ttf](https://github.com/mkxp-z/SDL_ttf)                 | mkxp-z         | zlib                           | mkxp-z fork  |
| [SDL_sound](https://github.com/mkxp-z/SDL_sound)             | git            | zlib                           | mkxp-z fork  |
| [FreeType](https://github.com/mkxp-z/freetype2)              | mkxp-z         | FreeType License (FTL) / GPLv2 | mkxp-z fork  |
| [PhysFS](https://github.com/icculus/physfs)                  | 3.2.0          | zlib                           | upstream     |
| [Pixman](https://gitlab.freedesktop.org/pixman/pixman)       | 0.42.2         | MIT                            | upstream     |
| [libpng](https://github.com/pnggroup/libpng)                 | 1.6.50         | libpng/zlib                    | upstream     |
| [libogg](https://github.com/xiph/ogg)                        | 1.3.6          | BSD-3-Clause                   | upstream     |
| [libvorbis](https://github.com/xiph/vorbis)                  | 1.3.7          | BSD-3-Clause                   | upstream     |
| [libtheora](https://github.com/xiph/theora)                  | HEAD           | BSD-3-Clause                   | upstream     |
| [uchardet](https://gitlab.freedesktop.org/uchardet/uchardet) | 0.0.8          | MPL 1.1 / GPLv2+ / LGPLv2.1+   | upstream     |
| [Ruby 1.8](https://github.com/joiplay/ruby)                  | ruby_1_8       | Ruby License / GPLv2           | JoiPlay fork |

The following Apple system frameworks are linked (no separate licensing required):

OpenGLES, OpenAL, Foundation, UIKit, CoreGraphics, CoreVideo, CoreAudio, AudioToolbox, AVFoundation, Metal, QuartzCore, GameController, CoreMotion, CoreBluetooth, CoreHaptics

### Bundled fonts

- **Liberation Sans** (SIL Open Font License 1.1)
- **WenQuanYi Micro Hei** (Apache License 2.0 / GPLv3)

### Preload scripts

- `win32_wrap.rb` by Ancurio and Splendide Imaginarius, released under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)
- `mkxp_wrap.rb` by Splendide Imaginarius, released under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)
- `ios_compat.rb`, `pokemon_compat.rb`, `pokemon_input.rb`, and `ruby_classic_wrap.rb` are part of this project

## License

mkxp-z is licensed under the **GNU General Public License v2** (see `mkxp-z/COPYING`).

The iOS-specific code in `ios/` is also GPLv2 to match.

Note that Ruby 1.8 is dual-licensed under the Ruby License and GPLv2, which is compatible with the rest of the project.

## Credits

- [Ancurio](https://github.com/Ancurio) for the original mkxp
- [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z) (Splendide Imaginarius, Savordez, Aeodyn, Eblo, and others)
- [JoiPlay](https://github.com/joiplay) for the Ruby 1.8 cross-compilation branch
