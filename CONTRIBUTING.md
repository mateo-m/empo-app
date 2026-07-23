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
xcodebuild -project ios/Empo/Empo.xcodeproj -target Empo \
  -sdk iphonesimulator -arch arm64 -configuration Debug build
```

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

If you explore the code, note these load-bearing tricks:

- **Multi-Ruby in one binary.** Three Ruby versions (1.8, 1.9, 3.1) compile separately. Then each version's libruby + binding code merges into one relocatable `.o`, with hidden symbol islanding via `ld -r --unexported_symbols_list`. Each `.o` exports exactly one global, `_mkxp_get_script_binding_NN`. The host applies a per-game session config (`mkxp_applySessionConfig()`) and the engine dispatches accordingly. See [`docs/multi-ruby.md`](docs/multi-ruby.md).
- **Persistent SDL + Ruby VM.** The app creates SDL, the GL context, OpenAL, and the active Ruby interpreter once and reuses them for the process lifetime. iOS does not let apps relaunch themselves between games, and CRuby's `ruby_init()` is one-shot per process.
- **Syntax-transform patches on Ruby 3.1.** The Ruby 3.1 build also applies [PR #304's parser patches](https://github.com/mkxp-z/mkxp-z/pull/304) so that mixed-grammar Pokemon Essentials forks (1.8 syntax + 1.9+ runtime methods) parse on Ruby 3.1's VM. The host activates LEGACY mode per game where needed. Otherwise vanilla 3.1 parsing applies.
- **Win32 emulation in Ruby.** [`win32_wrap.rb`](mkxp-z-apple-mobile/scripts/preload/win32_wrap.rb) (CC0, by Ancurio and Splendide Imaginarius) plus [`platform_compat.rb`](mkxp-z-apple-mobile/scripts/preload/platform_compat.rb) stub out the Windows APIs that games expect. They also neutralize `system`/`fork`/`spawn` so that games cannot launch new processes, and they swallow load errors from encrypted archives.
- **Touch controls via SDL events.** The overlay calls `SDL_PushEvent` with synthetic key events, so the engine sees them exactly as if they came from a hardware keyboard. New buttons or layouts need no engine changes.

## Pull requests

- Run `bun install` once after you clone so that LeftHook installs the empo-app hooks.
- If you will commit inside `mkxp-z-apple-mobile`, also run `(cd mkxp-z-apple-mobile && bun install)`.
- LeftHook enforces formatting and linting locally, and CI enforces them again.
- Get a green build on the iOS Simulator before you request review.
- Reference any related issue.
