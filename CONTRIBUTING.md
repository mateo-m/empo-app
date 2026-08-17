# Contributing to Empo

Issues, ideas, and PRs are welcome.

**Especially helpful:**

- Game compatibility reports. If a game crashes or renders wrong, open an issue with the title, version, and a description of what went wrong. Logs from Settings → Diagnostics help a lot.
- Engine bridge contributions. If you need the host to expose new state, open an issue first to discuss the API.

## Requirements

- macOS with Xcode 26 or newer (iOS 26 SDK).
- Homebrew (`xcodegen`, `autoconf`, `automake`, `libtool`, `cmake`, `pkg-config`).
- Apple developer account (required only for on-device builds).
- iPhone or iPad running iOS 26+ for on-device testing. iPhone 11 is the floor model.

## Build

Native libraries (OpenSSL, SDL, Ruby, mkxp-merged) ship as **prebuilt trees per SDK**, the same model as ANGLE. After you clone:

```sh
brew install bun xcodegen gh autoconf automake libtool cmake pkg-config
git clone --recursive git@github.com:mateo-m/empo-app.git
cd empo-app
bun install

# Hydrate ANGLE + native deps (downloads from empo-deps when published,
# or uses locally-built trees — see below)
xcodegen generate --spec ios/Empo/project.yml --project ios/Empo
xcodebuild -project ios/Empo/Empo.xcodeproj -scheme Empo \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

Build the scheme, not the target. A `-target` build resolves SwiftPM
packages through the legacy build system, which cannot find the
generated module map for the `json5cpp` C package and fails with
`module map file ... json5cpp.modulemap not found`.

### First-time / dep-bump setup

When `ios/Dependencies/native/.version` is still `unpublished`, or you changed a dependency version, build **both** SDK trees once (sequential, do not `make -j` everything):

```sh
scripts/rebuild-all-native-deps.sh
```

Published prebuilt trees live on the [empo-deps](https://github.com/mateo-m/empo-deps) releases repo. Maintainers refresh them with the **deps-publish** CI workflow. You need a local build only when you change a dependency yourself.

Verify a single tree:

```sh
PLATFORM_NAME=iphoneos scripts/verify-native-deps.sh
PLATFORM_NAME=iphonesimulator scripts/verify-native-deps.sh
```

### Editing engine binding code

Xcode does **not** compile `mkxp-z-apple-mobile/binding/*.cpp` (and `hmode7/`).
They are baked into the prebuilt `mkxp{18,19,31}-merged.o` objects.
After you edit them (or any engine header they include), rebuild the merged
objects for your target SDK:

```sh
cd ios/Dependencies
make -f iphonesimulator.make mkxp-merged   # or iphoneos.make
```

The merged targets track those sources as prerequisites, so this is a no-op
when nothing changed. The Xcode build verifies a content fingerprint of the
same source set on every build (`scripts/verify-native-deps.sh`) and fails
with a rebuild hint if the merged objects are stale.

### Simulator install

```sh
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
xcrun simctl install "$SIM" ios/Empo/build/Debug-iphonesimulator/Empo.app
xcrun simctl launch "$SIM" sh.mateo.empo
```

For device builds, swap `iphonesimulator` for `iphoneos` and create a gitignored `ios/Empo/Signing.xcconfig` with your `DEVELOPMENT_TEAM`.

## Notable hacks

If you read the code, note these unusual parts. The build depends on them:

- **Three Ruby versions in one binary.** Ruby 1.8, 1.9, and 3.1 compile separately. Each version's libruby and binding code then merges into one relocatable `.o`. `ld -r --unexported_symbols_list` hides every symbol but one, so the three copies cannot clash. Each `.o` exports a single global, `_mkxp_get_script_binding_NN`. The host sets a per-game session config with `mkxp_applySessionConfig()`, and the engine then picks the matching Ruby. See [`docs/multi-ruby.md`](docs/multi-ruby.md).
- **SDL and the Ruby VM stay alive.** The app creates SDL, the GL context, OpenAL, and the Ruby interpreter once. It then reuses them for the whole process. iOS does not let an app restart itself between games, and CRuby's `ruby_init()` runs only once per process.
- **Syntax patches on Ruby 3.1.** The Ruby 3.1 build applies [PR #304's parser patches](https://github.com/mkxp-z/mkxp-z/pull/304). They let Pokemon Essentials games that mix old syntax with newer methods parse on Ruby 3.1. The host turns on LEGACY mode for a game that needs it. Other games use plain 3.1 parsing.
- **Windows API stand-ins in Ruby.** [`win32_wrap.rb`](mkxp-z-apple-mobile/scripts/preload/win32_wrap.rb) (CC0, by Ancurio and Splendide Imaginarius) and [`platform_compat.rb`](mkxp-z-apple-mobile/scripts/preload/platform_compat.rb) replace the Windows functions that games expect. They also block `system`, `fork`, and `spawn`, so a game cannot start a new process. They hide load errors from encrypted archives.
- **Touch controls send SDL events.** The overlay calls `SDL_PushEvent` with made-up key events, so the engine reads them as it reads a real keyboard. New buttons or layouts need no engine change.

## Pull requests

- Run `bun install` once after you clone so that LeftHook installs the empo-app hooks.
- If you will commit inside `mkxp-z-apple-mobile`, also run `(cd mkxp-z-apple-mobile && bun install)`.
- LeftHook enforces formatting and linting locally, and CI enforces them again.
- Get a green build on the iOS Simulator before you request review.
- Reference any related issue.
