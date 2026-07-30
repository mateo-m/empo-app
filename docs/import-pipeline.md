# Game import pipeline

## Overview

There is no database: a game is a directory at `Documents/Games/<title>/`, named after the title
the game declares in its INI file and sanitized by `GameFolderName` (see `GameContainer.swift`).
The library holds **one container per title** - some games derive their data locations from
their INI title, so a suffixed duplicate would read the other copy's data. Before v0.5 the
folder was `<uuid>-<slug>`; `GameContainerMigration` renames legacy trees at launch and, when
several resolve to the same title, keeps the most recently played one under the canonical name
and moves the rest - whole, saves included - to the Files-visible `Documents/Duplicate Games/`,
telling the user via a one-time library alert that lists the moved copies.
An import turns the user's pick in Files into one such container per selected game. The import
seeds metadata and updates the library. It never shows a broken card and never leaves a
half-imported container behind.

The pipeline works in batches. It stages and extracts one source (archive or folder) **once**.
Then it moves each selected game root inside it into its own container. Probing, validation, and
title/artwork detection happen up front, during "resolution", before the pipeline commits any
card. The pipeline rejects invalid sources before any expensive work.

## Supported inputs

The document picker (`DocumentPickerView.swift`, `asCopy: true`, so iOS supplies a disposable
app-owned tmp copy) accepts:

- **Folders**: pre-extracted games.
- **`.zip` / `.7z` / `.rar`**: libarchive extracts these in streaming mode.
- **`.jgp`**: a JoiPlay bundle, a zip container with a `manifest.json` (see the JGP invariant
  below).
- **Self-extracting `.exe`**: Windows extractor stubs with the payload appended after the PE
  image. `ArchiveExtractor.sniffSfxPayload` sniffs the payload content. CAB payloads (RPG Maker's
  "Compress Game Data" output) go through the vendored **libmspack**, because libarchive
  mis-locates the cabinet and has a broken LZX decoder. 7z/RAR payloads go through libarchive via
  offset-translating callbacks. Zip-based SFX falls through to libarchive whole-file reading.

## Flow

An `os_signpost` interval wraps each phase (`ImportSignpost.swift`, subsystem `sh.mateo.empo`,
category `Import`). View the intervals in Instruments or with `log stream --signpost`.

1. **Resolution** (`ImportPipeline`, `@MainActor`): picked URLs queue as `QueuedImportRequest`s.
   The pipeline resolves them serially, one `ImportPipelineSession` at a time.
   - `stage-source`: the pipeline renames archives (move, with copy fallback) into
     `tmp/empo-import/staged-archives/<uuid>/`. Folders pass through untouched at this point.
   - `probe`: `GameImportValidator.importRootChoices` runs **one** selective walk of the archive
     (`ArchiveExtractor.extractSelective`). The walk pulls `.ini`, `mkxp.json`, `Data/Scripts.*`,
     `.exe` files, and `Graphics/Titles/*` previews into a scratch dir. The probe validates every
     candidate root and returns `ImportRootChoice` values (relativePath, title, subtitle, preview
     artwork). It also returns an `ArchiveExtractor.Inventory` (entry count + uncompressed byte
     totals) that later drives byte-accurate extraction progress. The probe rejects invalid
     sources (not an RPG Maker game, unsupported RGSS version, corrupt archive) here, before any
     card exists.
   - When more than one valid root exists, the stepped root-picker sheet appears
     (`ImportRootPickerSheet`): step one, **Add Games**, lists roots not in the library
     (selection starts empty); step two, **Update Games**, lists roots whose sanitized title
     matches an installed game (selection starts full - importing them updates that install in
     place). A source with only one category shows only that step. The classification
     (`ImportRootPrompt.updatingChoiceIDs`) is display-advisory; `planImports` re-derives it at
     confirm time. When exactly one root exists, the import starts automatically - and if that
     one game is installed, the plain "Update Game?" alert (`ImportReplacePrompt`) asks first.
     The alert also serves as a fallback for updates the picker didn't approve (a game whose
     installed status changed while the sheet was open).
   - `planImports` then fixes each selection's destination folder name (the sanitized title). A
     name owned by another **in-flight** import is refused with an alert (no silent suffixed
     duplicate). A name owned by an **installed** game becomes an update-in-place plan:
     confirmed updates merge the new files into an APFS-cloned staging copy of `Game/` and swap
     in atomically (`GameImporter.stageAndSwapGameTree`), overwriting same-path files and
     keeping everything else (saves, settings, metadata, and game files the new version doesn't
     ship); any failure before the swap leaves the installed tree untouched. The scan recovers
     crash leftovers (`cleanupStaleUpdateStaging` → `GameTreeUpdate.sweepInterruptedUpdate`): a
     kill between the swap's two renames leaves no `Game/`, so the sweep RESTORES the merged
     staging tree (or the backup) before removing artifacts - never sweep-then-orphan-delete.
     Declining an update drops just that selection, and updates already approved in the picker
     survive a decline of the fallback alert. Suffixed names are never minted (one container per title): a
     second same-title selection in one batch is refused with an alert, as is an update that
     targets the currently open (playing/paused) game.
2. **Batch import** (`GameLibrary.pipelineImportGames`, `ImportPipeline.swift` ~line 509): one
   detached task per **source** fans out per-selection state (`BatchSelection`). The main actor
   registers pending entries and `inFlightImports` membership before the task starts.
   - **Archives**: for each selection, the task creates a `GameContainer`, writes the probe's
     `.exe` icon (if any) as a sidecar, commits the card (`commitPendingToCard`), and sets up an
     `ExeIconSurfacer`. Then one `extract` interval extracts the whole archive to one tmp dir.
     Progress scales into `[0, 0.95]` and fans out to every active card. The task drains the
     surfacers before any move.
   - **Folders**: `stage-source` (move, else copy, into tmp), then `validate`
     (`GameImportValidator.validate`). Cards commit at progress 0.5 with `Graphics/Titles`
     artwork (`GameCatalog.findFolderImportArtwork`).
   - `move`: the task processes selections **deepest relativePath first**, so a nested selected
     root moves out before a shallower one can swallow it. The steps: resolve the root, run
     `preprocessJgp` (`.jgp` only), move into `container.gameURL`, run
     `normalizeImportedGamePermissions`, set progress 0.97.
   - `finalize`: `finalizeJgpImport`, `createMetadata` (archives), or `seedFolderImport`
     (folders). All three run `GameScriptProfile.analyze` (in the `ios/GameProbe` package) to
     detect the Ruby version and modern scripts. If extraction surfaced no icon, archives also
     get a fallback `ExecutableIconExtractor.writeSidecarIfPossible`. At progress 1.0, the
     selection leaves `inFlightImports`. Then `GameLibrary.mergeImportedGame(container:)`
     (`GameLibrary.swift` ~line 184) merges the single finished entry into `games`, with no full
     library rescan.
   - Completion (main actor): the task cleans up the staged source, fires a haptic on any
     success, and shows one alert for the first non-cancelled failure.
   - `library-scan` / `library-quick-scan`: full-disk rescans. Only `reload()` (app launch, merge
     fallback, deletion errors) uses these, not the import completion path.

## Invariants

These invariants match the current code. Do not break them.

1. **Zip-slip defense**: the extractor rejects entries whose normalized path starts with `/` or
   contains a `..` component. `ArchiveExtractor.extract` and `cabExtract` throw
   `Error.pathEscape`. The selective variants skip the entry. `GameImportValidator.resolveGameRoot`
   independently re-checks path containment (prefix + `..` component check) when it resolves a
   selection's relativePath. Never replace the extractor's component-level checks with a
   filesystem-path prefix check. That check false-positives on device: `/var` is a symlink to
   `/private/var`, so standardized paths compare unequal.
2. **Cancellation contract**: `GameLibrary.cancelledImports` (`Mutex<Set<String>>`) signals a
   cancel. Every long phase checks it through `isImportCancelled(_:)`, and the `shouldCancel`
   closure reports it as `ArchiveExtractor.Error.cancelled`. During a shared extract,
   `shouldCancel` aborts only when the user cancels **all** selections. `checkCancellations()`
   inside the progress callback drops individually cancelled selections promptly. A cancelled
   selection ends with `abandonImport` (it deletes the partial container and removes the pending
   entry and card). It never surfaces an alert, because `ImportPipeline.startImports`'s
   completion filters out `ImportCancelled` failures. Every exit path clears the cancellation
   flag (`defer` in `pipelineImportGames`).
3. **Out-of-space mapping**: any error that satisfies `GameLibrary.isOutOfSpace`
   (`NSFileWriteOutOfSpaceError` or POSIX `ENOSPC`) must surface as `ImportError.outOfSpace`. See
   the move catch and the outer catch in `pipelineImportGames`.
4. **In-flight guard ordering**: the pipeline inserts an importID into `inFlightImports` before
   it creates any container directory (in practice, before the detached task starts). It removes
   the importID only after it moves the game fully and writes its metadata, but **before**
   `mergeImportedGame` or `reload` runs on the main actor. `reload()` passes the in-flight set as
   `skipIDs`. A concurrent scan thus never sees a container whose `Game/` subdir is not in place
   yet, and never clobbers the progress card with an "Unknown Game" invalid entry.
5. **UI lifecycle**: pending entry (`pendingImports`) → committed card (`commitPendingToCard`,
   status `.importing(progress:)`) → final entry via merge. Resolution and validation failures
   drop the pending entry and never commit a card. `ImportPipeline.importButtonPhase` derives
   from `currentSession` + `pendingImports`. Keep it accurate.
6. **Container hygiene**: after a selection's container exists, the `committed` flag +
   `defer { container.deleteAll() }` pattern guarantees cleanup on any failure - for **fresh
   imports only**. A replacement (`GameLibrary.replacingImports`) never deletes its container on
   failure or cancel: it is the installed game, saves included, and the staged atomic swap
   means its `Game/` tree is either fully updated or exactly as it was. `abandonImport`
   re-surfaces the existing entry instead of deleting.
   `GameContainer.normalizeImportedGamePermissions` runs after **every** move into `Game/`.
   `ensureGamesDirectory` / `ensureSubdirs` handle the iCloud-backup exclusion. Do not remove
   those calls.
7. **JGP behavior**: `.jgp` imports run `GameImporter.preprocessJgp` **before** the move. This
   step parses the manifest, checks runtime support, and strips `manifest.json`,
   `configuration.json`, and the icon from the game tree. They run `finalizeJgpImport` **after**
   the move. This step applies settings from the JoiPlay configuration, the manifest title and
   metadata, and custom artwork from the manifest icon.
8. **Artwork policy**: during archive extraction, only `.exe` icons surface mid-import, never
   `Graphics/Titles/*` previews. A surfaced title-screen preview flashes, and then the final
   artwork pick replaces it. The `onFileWritten` callback filters to `.exe` files at the
   selection root or one level below (`isRootLevelExe`). It matches each file to the deepest
   owning selection (`matchingSelection`). `Game.exe` locks the choice (`ExeIconSurfacer`). The
   callback skips utility executables (`ExecutableIconExtractor.isUtilityExecutable`). The
   probe-seeded card artwork uses `ImportRootChoiceArtwork.iconData` only, never `imageData`.
   Icon work runs on the surfacer's own queue, never on the extraction thread. The task drains
   it before the move.

## Key files

| File                                             | Role                                                                               |
| ------------------------------------------------ | ---------------------------------------------------------------------------------- |
| `ios/Empo/src/Library/DocumentPickerView.swift`  | Picker (`asCopy: true`), accepted UTTypes                                          |
| `ios/Empo/src/Library/ImportPipeline.swift`      | `ImportPipeline` resolution queue/session/alerts, `pipelineImportGames` batch body |
| `ios/Empo/src/Library/GameImportValidator.swift` | Probe (`importRootChoices`), root discovery/validation, `resolveGameRoot`          |
| `ios/Empo/src/Library/ArchiveExtractor.swift`    | libarchive + libmspack streaming extraction, SFX payload sniffing, `Inventory`     |
| `ios/Empo/src/Library/ExeIconSurfacer.swift`     | Off-thread PE icon extraction for mid-import card artwork                          |
| `ios/Empo/src/Library/GameImporter.swift`        | Metadata seeding, JGP preprocess/finalize                                          |
| `ios/Empo/src/Library/GameLibrary.swift`         | Library state, `mergeImportedGame`, `inFlightImports`, tmp-dir helper              |
| `ios/Empo/src/Library/GameCatalog.swift`         | Disk scan → `GameEntry`, artwork lookup                                            |
| `ios/Empo/src/Library/ImportSignpost.swift`      | `os_signpost` phase instrumentation                                                |
| `ios/GameProbe/`                                 | Swift package: `GameScriptProfile`, `GameINI`, config parsing (Linux-testable)     |
