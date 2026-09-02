# deps-publish: engine-only mode

Status: implemented on 2026-09-02. This note records the rules and
why they are what they are.

## The problem

`deps-publish` builds two trees on the Mac runner, one per SDK. Each
tree takes about 610 seconds. The engine halves (`mkxp*-merged.o` and
`libmkxpz-core.a`) take about 120 of those seconds. The other 490
seconds rebuild SDL, Ruby, OpenSSL, and the rest from a clean source
tree, because `scripts/rebuild-device-deps.sh` and its simulator twin
start with `git clean -fdx` in every source submodule.

Most deps-publish runs change only the engine. The dependency half of
the new tarball is byte-for-byte the same work as the last one.

ccache does not help here. The dependency compiles already run with
`-j$(NPROC)`. The serial parts (configure, CMake configure, link,
install) set the wall clock, and no compiler cache touches them. Full
ccache coverage measured 27% slower cold and 2% faster warm.

The only lever left is to not rebuild the dependency half at all.

## The rule that makes this safe

A tree is correct only when its two halves come from the same inputs.
The engine-only path reuses the dependency half of an older tarball.
That is safe only when nothing that feeds the dependency half moved
since that tarball was built.

So the design is one question with a fail-closed answer. Compute a hash
of every committed input to the dependency half. If the hash of the
checkout equals the hash stored in the base tarball, and the SDK is the
same, take the short path. In every other case, or when anything is
unclear, run the full build.

This is the same idea Nix and Bazel use. Key the cache on the hash of
the inputs, never on the age or the presence of the outputs.

## The dependency fingerprint

`tools/deps-fingerprint.sh` prints one SHA-256 for the committed inputs
of the dependency half. The value is the same for both SDKs and on
every machine.

### Inputs

Everything comes from git objects, not from the working tree. The
working tree lies twice. Patches change the source files after
checkout. `git archive` of the top repo skipped the `hmode7` submodule
on 2026-09-01 and produced a wrong fingerprint without an error. The
script reads `git ls-files -s`, which lists a submodule as its gitlink
commit and a directory as every tracked file under it.

| Input | Why |
| --- | --- |
| The nine dependency submodules under `ios/Dependencies/sources/` | The sources |
| `ios/Dependencies/common.make`, `iphoneos.make`, `iphonesimulator.make` | Versions, flags, the OpenSSL pin, the minimum OS |
| `ios/Dependencies/*.patches.lst` and `apply-*-patches.sh` | Which patches apply, and how |
| The patch directories `pixman`, `ruby18`, `ruby19`, `ruby31`, `sdl2`, `sdl2_image`, `sdl2_ttf`, `sdl_sound` | The patches |
| `scripts/rebuild-device-deps.sh`, `scripts/rebuild-simulator-deps.sh` | The build order |
| `tools/deps-fingerprint.sh` itself | A change to the input list forces a full build |

The SDK version is not in the hash. `scripts/verify-native-deps.sh`
recomputes the hash on every developer's Mac, with whatever Xcode is
installed, and a tarball built with an older SDK is still correct to
link. The workflow compares the SDK version as a second condition
instead. `tools/package-native-deps.sh` writes it to
`ios/Dependencies/native/.version` as `NATIVE_DEPS_SDK_VERSION`, and
`scripts/rebuild-engine-halves.sh` compares it with the `MANIFEST` of
the tree. A dependency half built with SDK 26.0 under an engine half
built with SDK 26.1 is a mixed tree. An Xcode update on the runner
forces one full build. That costs ten minutes a few times a year.

### Rules for the script

- It hashes a fixed-format text, one `path<TAB>hash` line per input,
  sorted. `--list` prints that text. The workflow prints it into the
  log on every run.
- If any listed path is not tracked, it fails with the path in the
  message. It does not skip it. The `binding-fingerprint.sh` count
  guard (at least ten files) let the `hmode7` gap through. This
  script checks each path by name.
- `--require-clean` fails when a listed file has uncommitted changes
  or a submodule's HEAD is not its gitlink. It does not look at
  modified files inside a submodule. Every dependency rule runs
  `git checkout -- .` before it applies patches, so a previous build
  always leaves them modified. An uninitialized submodule passes,
  because the full build fails on it anyway and the engine-only path
  never reads it.

### Where the stamp lives

The full rebuild scripts compute the hash before the build patches the
sources. They write it to `build-<sdk>-arm64/lib/.deps-fingerprint`
after the last dependency target succeeds and before the engine targets
run. A failed dependency build leaves no stamp. This is the same rule
`.mkxp-binding-fingerprint` follows.

`tools/package-native-deps.sh` refuses to package a tree without the
stamp or the `MANIFEST`, and refuses when the two trees carry different
stamps, modes, or SDK versions. It ships both files in the tarball and
writes the stamp into `native/.version` as `NATIVE_DEPS_FINGERPRINT`.

`scripts/verify-native-deps.sh` recomputes the hash at consumption and
compares it with the stamp, the same way it compares the binding and
core fingerprints. A submodule bump without a republish fails the
Xcode build instead of linking the old archives. A tree without the
stamp fails too. `EMPO_ALLOW_UNSTAMPED=1` keeps its meaning.

## The workflow

### New input

`mode`, with three values:

| Value | Behaviour |
| --- | --- |
| `auto` (default) | Take the engine-only path when the fingerprint and the SDK match. Run the full build in every other case, and say why in the log. |
| `full` | Always run the full build. |
| `engine` | Require the engine-only path. Fail the job when it does not apply. |

`engine` exists so a person can prove the short path works, and so a
run that was meant to be cheap does not silently become a ten-minute
one.

### The decision, per matrix job

Each build-tree job decides for its own SDK, before any build:

1. Check out the branch with the engine submodule and all dependency
   submodules.
2. Run `tools/deps-fingerprint.sh --require-clean`. Call the result
   `current`.
3. Read `native/.version`. Call the tag `base`.
4. Pick the path. The first rule that applies wins.
   - `mode=full`: full.
   - `base` is `unpublished`: full.
   - `NATIVE_DEPS_FINGERPRINT` is empty (a tarball from before this
     change): full.
   - `current` differs from `NATIVE_DEPS_FINGERPRINT`: full.
   - The SDK version of this Mac differs from
     `NATIVE_DEPS_SDK_VERSION`: full.
   - The release for `base` is not on empo-deps: full.
   - Otherwise: engine-only.
5. In `mode=engine`, any answer other than engine-only fails the job.

There are no job outputs. Each tree carries its `mode` in its
`MANIFEST`, and `tools/package-native-deps.sh` fails when the two
trees disagree. With one runner they see the same checkout and the
same SDK, so they agree. The check is there for the day there are two
runners with two Xcode versions.

### The engine-only path

`scripts/rebuild-engine-halves.sh <sdk> --hydrate` does all of it. The
workflow does not call `tools/fetch-native-deps.sh` here. That script
verifies the extracted trees, and the verify compares the binding
stamp with the checked-out engine. It fails exactly when the engine
moved, which is the case this path exists for.

1. Download the release pinned in `native/.version`, check its
   SHA-256, and replace the tree for this SDK with the one in the
   tarball.
2. Refuse when the tree has no stamp or no `MANIFEST`.
3. Refuse when the stamp differs from `current`. A mismatch here means
   `.version` and the tarball disagree. That is corrupt data and needs
   a person. There is no fallback to full.
4. Refuse when the SDK version in the `MANIFEST` differs from this
   Mac's SDK.
5. Record the SHA-256 of every file that is not an engine output.
6. Delete every engine output. Do not rely on mtimes to force the
   rebuild.
7. Run make (see below).
8. Record the SHA-256 of every non-engine file again. Any difference
   fails the run.
9. Run `scripts/verify-native-deps.sh` with the core check on, the
   same call the full path makes.
10. Write the `MANIFEST`.

Without `--hydrate` the script uses the tree on disk, which is what an
Xcode build left there. That is the local use: edit the engine, rebuild
the halves, no download.

### Provenance

Each tree carries a `MANIFEST`, and the release notes show both. Fields:

- `mode`: `full` or `engine`.
- `sdk`, `sdk_version`, `xcode_build`.
- `deps_fingerprint`.
- `deps_built_at`: when the dependency half was built. A full build
  writes the current time. An engine build copies the value from its
  base. This shows how old the dependency half is after a chain of
  engine builds.
- `base_tag`: the tag the dependency half came from, or `none`.
- `empo_commit`, `engine_commit`, `built_at`.

The publish rules stay as they were. Tags are immutable. A repeat
under the same tag with the same SHA-256 is a no-op. A repeat with a
different SHA-256 is a hard error.

### Concurrency

The workflow has a `concurrency` group named `deps-publish` with
`cancel-in-progress: false`. Two dispatches used to race for one Mac
and for the pin commit. The engine path makes runs short enough that
two people will dispatch close together.

## The makefile change

This is the part with the real trap. The obvious command,
`make -f iphoneos.make mkxp-merged mkxp-core` on a hydrated tree,
rebuilds Ruby and OpenSSL.

The chain is `mkxp31-merged` → `ruby` → `openssl` and
`$(LIBDIR)/libruby.3.1-static.a` → `$(SOURCES)/ruby/.configured-iphoneos-arm64`.
A fresh checkout has no `.configured-*` stamp, because that stamp lives
in the source submodule and the runner cleans it. make sees a missing
prerequisite with a rule, so it runs configure, and configure rebuilds
the archive. The `openssl` chain does the same through
`$(OPENSSL_CONFIGURED)`, which lives under `downloads/`.

Order-only prerequisites do not help. make still builds a missing
order-only prerequisite.

Two changes fix this.

### One target for the engine halves

The binding stamp is a file target, and both paths build one target.
The recipe line starts with a tab in the real file.

```make
$(LIBDIR)/.mkxp-binding-fingerprint: $(LIBDIR)/mkxp18-merged.o $(LIBDIR)/mkxp19-merged.o $(LIBDIR)/mkxp31-merged.o
    $(ENGINE)/tools/binding-fingerprint.sh > $@

mkxp-merged: mkxp18-merged mkxp19-merged mkxp31-merged $(LIBDIR)/.mkxp-binding-fingerprint

engine-halves: init_dirs $(LIBDIR)/.mkxp-binding-fingerprint $(LIBDIR)/libmkxpz-core.a
```

The stamp still appears only after all three objects exist. The full
path keeps `mkxp-merged` and `mkxp-core` and changes nothing else.
There is one recipe for the stamp instead of two.

### Tell make the Ruby archives are final

`scripts/rebuild-engine-halves.sh` runs make with `-o` for each Ruby
archive:

```sh
LIB="$PWD/build-$SDK-arm64/lib"
make -f "$SDK.make" \
  -o "$LIB/libruby.3.1-static.a" -o "$LIB/libruby.3.1-ext.a" \
  -o "$LIB/libruby18-static.a"   -o "$LIB/libruby18-ext.a" \
  -o "$LIB/libruby19-static.a"   -o "$LIB/libruby19-ext.a" \
  engine-halves
```

`-o file` tells make the file is up to date and that its own rules do
not apply. make never looks at `.configured-*` for it. The name must be
the exact string the makefile uses for the target. `LIBDIR` expands to
`${PWD}/build-<sdk>-<arch>/lib`, so the script passes the absolute path.

The engine build reads from the tree, the engine submodule, ANGLE, and
the SDK only. Checked on 2026-09-02: `build-binding-ios.sh` takes its
Ruby headers from `--ruby-include $(INCLUDEDIR)/rubyNN`, its dependency
headers from `$(INCLUDEDIR)/{SDL2,pixman-1,uchardet,freetype2}`, and
the Ruby archives from `$(LIBDIR)`. `build-core-ios.sh` reads the same
include dirs plus `AL`. Neither script reads `sources/`. The tarball
ships every one of those directories. ANGLE comes from
`tools/fetch-angle.sh`, which the workflow runs before the build.

## The guard that catches everything else

Steps 5 and 8 above compare every file that is not an engine output
before and after the make run. This check does not care why the
dependency half changed. A make rule that cascaded, a patch applied
twice, a script that touched one file, all fail the same way. It costs
one `shasum` pass over the tree.

The list of engine outputs is in the script. A new engine output shows
up as a new file and fails the run. Add it to the list on purpose.

## Edge cases, in one place

| Case | Result |
| --- | --- |
| Base tag deleted, or asset missing | `auto`: full. `engine`: fail. |
| `.version` says `unpublished` | full |
| Old tarball with no stamp | `auto`: full. `engine`: fail. |
| Any dependency submodule moved | Fingerprint differs → full |
| A patch file, a patches list, or a makefile changed | Fingerprint differs → full |
| `tools/deps-fingerprint.sh` changed | It hashes itself → full |
| Uncommitted change to an input, or a submodule not at its gitlink | Fingerprint script fails → job fails |
| Modified files inside a submodule from an earlier build | Ignored. The build resets them before it patches. |
| Xcode or SDK update on the runner | SDK version differs → full |
| Engine submodule moved | Not an input. Engine-only path, as intended. |
| Engine change that needs a new dependency patch | The patch lands in Empo's patch files → full |
| `.version` and the tarball disagree on the fingerprint | Fail after download. No fallback. |
| The two matrix jobs picked different paths | Package step fails |
| A dependency file differs after the engine build | Engine script fails |
| Chain of engine builds on engine builds | Safe by the file-hash guard. `deps_built_at` shows the age. |
| Two dispatches at once | Concurrency group queues the second |
| Same tag, same bytes | No-op, as before |
| Same tag, different bytes | Hard error, as before |

## Verification plan

Each one is a throwaway branch and a throwaway `native-probe-*` tag.
Delete the tags with `gh release delete --yes --cleanup-tag` after, and
drop the pin commits.

1. A/B on one commit. Run `mode=full` and `mode=engine` from the same
   Empo commit and the same engine commit, with the full run's release
   as base. Compare `nm -g` output and file sizes for the three merged
   objects and the core archive. Compare `verify-native-deps.sh`
   output. Both must pass, and the symbol lists must match.
2. Negative test, input moved. Bump one line in `sdl2.patches.lst` on
   the branch. `auto` must log the mismatch and go full. `engine` must
   fail before it downloads anything.
3. Negative test, corrupt stamp. Edit `.deps-fingerprint` in a tree
   and run `rebuild-engine-halves.sh`. It must fail with the mismatch
   message.
4. Negative test, cascade. Delete `lib/libruby18-static.a` from the
   tree by hand, then run `rebuild-engine-halves.sh`. make must fail
   on the missing file. It must not rebuild Ruby.
5. Timing. Record the step time of the engine path per tree. The
   estimate is 120 seconds. If it is over 200, find out what ran.
6. Consumption. Build the app in CI against the engine-mode tarball and
   run the engine tests.

## What this does not fix

- `binding-fingerprint.sh` still has the weak count guard. Fix it in
  the engine repo. It is the same class of bug.
- The OpenSSL tarball has a version pin and no checksum. `common.make`
  downloads it by URL and trusts the bytes. Add a pinned SHA-256.
- `common.make` clones theora without a tag or a commit. Two full
  builds a month apart can compile different theora sources. The
  fingerprint cannot see that. Pin it.
- The full path still wipes every source tree. That is correct for a
  release build and stays.

## Files this touches

| File | Change |
| --- | --- |
| `tools/deps-fingerprint.sh` | New |
| `scripts/rebuild-engine-halves.sh` | New, takes the SDK name and `--hydrate` |
| `scripts/write-deps-manifest.sh` | New |
| `scripts/rebuild-device-deps.sh`, `scripts/rebuild-simulator-deps.sh` | Compute the hash first, write the stamp after the last dependency target, write the `MANIFEST` last |
| `ios/Dependencies/common.make` | Stamp file target, `engine-halves` target |
| `tools/package-native-deps.sh` | Require stamp and `MANIFEST`, check the trees agree, write two new `.version` fields, release notes |
| `scripts/verify-native-deps.sh` | Compare `.deps-fingerprint` |
| `.github/workflows/deps-publish.yml` | `mode` input, decision step, engine path, concurrency group |
| `tools/fetch-native-deps.sh` | No change |
