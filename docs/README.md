# Empo documentation

This folder is the source of the [Empo documentation site](https://mateo-m.github.io/empo-app/).
Each `.md` and `.mdx` file here becomes a page. Run `bun run docs:dev` from the repository root
to read it in a browser, or read the files below on GitHub.

Start with the [project README](../README.md) for what Empo is and how to build it.

## For players

| Doc                                          | What it covers                                                     |
| -------------------------------------------- | -------------------------------------------------------------------- |
| [`install.mdx`](install.mdx)                 | Requirements, and how to sideload the app.                         |
| [`importing-games.mdx`](importing-games.mdx) | The accepted file types, and what happens to an installed game.    |
| [`playing.mdx`](playing.mdx)                 | The library, the touch controls, controllers, and game settings.   |
| [`troubleshooting.mdx`](troubleshooting.mdx) | Frequent problems, and how to collect logs for a report.           |

## For game developers

Reference docs for shipping or adapting an RPG Maker game for Empo:

| Doc                                        | What it covers                                                                               |
| ------------------------------------------ | -------------------------------------------------------------------------------------------- |
| [`controls-format.md`](controls-format.md) | The `empo/controls.json` touch-controls manifest: format, validation codes, controller maps. |
| [`config-format.md`](config-format.md)     | The JSON5 language that both the app and the engine parse, and its quirks.                   |
| [`patches-format.md`](https://github.com/mateo-m/mkxp-z-apple-mobile/blob/main/docs/patches-format.md) (engine repo) | The `patches.json` script-patching system: format, matching semantics, when patches apply. |
| [`schemas/`](schemas/)                     | JSON Schemas (e.g. `empo-controls.v1.schema.json`).                                          |
| [`examples/`](examples/)                   | Worked examples (e.g. a complete `controls.json`).                                           |

## How Empo works (contributors)

Explanations of the trickier architecture, in rough reading order:

| Doc                                                  | What it covers                                                                     |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [`how-it-works.mdx`](how-it-works.mdx)               | The architecture in one page, with links to each detailed note.                     |
| [`multi-ruby.md`](multi-ruby.md)                     | Three Ruby interpreters in one binary, with per-game version detection and dispatch. |
| [`sdl-ruby-workarounds.md`](https://github.com/mateo-m/mkxp-z-apple-mobile/blob/main/docs/sdl-ruby-workarounds.md) (engine repo) | Why SDL, the GL context, OpenAL, and the Ruby VM persist for the process lifetime. |
| [`multi-session.md`](multi-session.md)               | Why cross-session play is disabled, and the neutralized quit paths.                |
| [`pause-resume.md`](pause-resume.md)                 | Frozen-frame snapshots that bridge the SDL window into SwiftUI transitions.        |
| [`import-pipeline.md`](import-pipeline.md)           | The game import pipeline: supported inputs, stage flow, invariants.                |
| [`sheet-design.md`](sheet-design.md)                 | The rules that keep every bottom sheet consistent.                                 |
| [`deps-publish-engine-only.md`](deps-publish-engine-only.md) | How deps-publish reuses a published dependency half and rebuilds only the engine. |

`media/` holds the README screenshots and demo assets. The site configuration lives in
[`blume.config.ts`](../blume.config.ts), and site-wide static files live in [`public/`](../public).
