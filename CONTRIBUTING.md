# Contributing to Empo

Issues, ideas, and PRs are welcome.

**Especially helpful:**

- Game compatibility reports. If a game crashes or renders wrong, open an issue with the title, version, and a description of what went wrong. Logs from Settings → Diagnostics help a lot.
- Engine bridge contributions. If you need the host to expose new state, open an issue first to discuss the API.

## Requirements

- macOS with Xcode 26 or newer (iOS 26 SDK).
- Homebrew (`xcodegen`, `gh`).
- Apple developer account (required only for on-device builds).
- iPhone or iPad running iOS 26+ for on-device testing. iPhone 11 is the floor model.

## Build

Each core comes from the release of its own repo: [mkxp-z-apple-mobile](https://github.com/mateo-m/mkxp-z-apple-mobile), [psdk-apple-mobile](https://github.com/mateo-m/psdk-apple-mobile), and [mvmz-apple-mobile](https://github.com/mateo-m/mvmz-apple-mobile). The Xcode build downloads the release that `cores/<core>/.version` pins, and wraps it in a framework. After you clone:

```sh
brew install bun xcodegen gh
git clone git@github.com:mateo-m/empo-app.git
cd empo-app
bun install

xcodegen generate --spec ios/Empo/project.yml --project ios/Empo
xcodebuild -project ios/Empo/Empo.xcodeproj -scheme Empo \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

Build the scheme, not the target. A `-target` build resolves SwiftPM
packages through the legacy build system, which cannot find the
generated module map for the `json5cpp` C package and fails with
`module map file ... json5cpp.modulemap not found`.

### Change an engine

Make the change in the engine repo, and follow the build steps of its README. When its release workflow publishes a new version, set the version and the sha256 from the release notes in `cores/<core>/.version`.

To test an engine build before its release, put the tarball of `tools/package-ios.sh` in `ios/Dependencies/mkxp-core.tar.gz`, and set `MKXP_CORE_SHA256` in `cores/mkxp/.version` to its sha256.

### Simulator install

```sh
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
xcrun simctl install "$SIM" ios/Empo/build/Debug-iphonesimulator/Empo.app
xcrun simctl launch "$SIM" sh.mateo.empo
```

For device builds, swap `iphonesimulator` for `iphoneos` and create a gitignored `ios/Empo/Signing.xcconfig` with your `DEVELOPMENT_TEAM`.

### Tests

`scripts/run-swift-tests.sh` runs the GameProbe and Json5 package tests on macOS.

`EmpoTests` runs inside the app on a simulator. It drives `ControllerInputManager` with snapshot controllers (`GCController.withMicroGamepad()`, `withExtendedGamepad()`), so it covers the controller path without a physical pad:

```sh
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
xcodebuild test -project ios/Empo/Empo.xcodeproj -scheme Empo \
  -destination "id=$SIM" -only-testing:EmpoTests CODE_SIGNING_ALLOWED=NO
```

## Notable hacks

If you read the code, note these unusual parts. The build depends on them:

- **Three Ruby versions in one binary.** Ruby 1.8, 1.9, and 3.1 compile separately. Each version's libruby and binding code then merges into one relocatable `.o`. `ld -r --unexported_symbols_list` hides every symbol but one, so the three copies cannot clash. Each `.o` exports a single global, `_mkxp_get_script_binding_NN`. The host sets a per-game session config with `gamecore_applySessionConfig()`, and the engine then picks the matching Ruby. See [`ios/Empo/docs/multi-ruby.md`](ios/Empo/docs/multi-ruby.md).
- **SDL and the Ruby VM stay alive.** The app creates SDL, the GL context, OpenAL, and the Ruby interpreter once. It then reuses them for the whole process. iOS does not let an app restart itself between games, and CRuby's `ruby_init()` runs only once per process.
- **Syntax patches on Ruby 3.1.** The Ruby 3.1 build applies [PR #304's parser patches](https://github.com/mkxp-z/mkxp-z/pull/304). They let Pokemon Essentials games that mix old syntax with newer methods parse on Ruby 3.1. The host turns on LEGACY mode for a game that needs it. Other games use plain 3.1 parsing.
- **Windows API stand-ins in Ruby.** [`win32_wrap.rb`](https://github.com/mateo-m/mkxp-z-apple-mobile/blob/dev/scripts/preload/win32_wrap.rb) (CC0, by Ancurio and Splendide Imaginarius) and [`platform_compat.rb`](https://github.com/mateo-m/mkxp-z-apple-mobile/blob/dev/scripts/preload/platform_compat.rb) replace the Windows functions that games expect. They also block `system`, `fork`, and `spawn`, so a game cannot start a new process. They hide load errors from encrypted archives.
- **Touch controls send SDL events.** The overlay calls `SDL_PushEvent` with made-up key events, so the engine reads them as it reads a real keyboard. New buttons or layouts need no engine change.

## Pull requests

- Run `bun install` once after you clone so that LeftHook installs the empo-app hooks.
- LeftHook enforces formatting and linting locally, and CI enforces them again.
- Get a green build on the iOS Simulator before you request review.
- Reference any related issue.
