# Empo documentation

Start with the [project README](../README.md) for what Empo is, how to build it, and how to
import games.

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
| [`multi-ruby.md`](multi-ruby.md)                     | Three Ruby interpreters in one binary, with per-game version detection and dispatch. |
| [`sdl-ruby-workarounds.md`](https://github.com/mateo-m/mkxp-z-apple-mobile/blob/main/docs/sdl-ruby-workarounds.md) (engine repo) | Why SDL, the GL context, OpenAL, and the Ruby VM persist for the process lifetime. |
| [`multi-session.md`](multi-session.md)               | Why cross-session play is disabled, and the neutralized quit paths.                |
| [`pause-resume.md`](pause-resume.md)                 | Frozen-frame snapshots that bridge the SDL window into SwiftUI transitions.        |
| [`import-pipeline.md`](import-pipeline.md)           | The game import pipeline: supported inputs, stage flow, invariants.                |
| [`save-states.md`](save-states.md)                   | Research: what save states can mean for Empo, prior art, and the recommended design. |

`media/` holds the README screenshots and demo assets.
