#!/usr/bin/env node
/**
 * Generates docs/schemas/empo-controls.v1.schema.json from GameProbe source.
 * Run: node tools/generate-controls-schema.mjs
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");

function read(relPath) {
  return fs.readFileSync(path.join(repoRoot, relPath), "utf8");
}

function extractKeyCodes(swift) {
  const codes = [];
  const re = /Entry\(code: "([^"]+)"/g;
  let match;
  while ((match = re.exec(swift)) !== null) {
    codes.push(match[1]);
  }
  if (codes.length === 0) {
    throw new Error("no key codes found in KeyCodeTable.swift");
  }
  return codes;
}

function extractControllerElements(swift) {
  const block = swift.match(/allElements: \[String\] = \[([\s\S]*?)\]/);
  if (!block) {
    throw new Error("controller element list not found in ControlsManifest.swift");
  }
  const elements = [...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  if (elements.length === 0) {
    throw new Error("no controller elements found");
  }
  return elements;
}

const keyCodes = extractKeyCodes(read("ios/GameProbe/Sources/GameProbe/Controls/KeyCodeTable.swift"));
const controllerElements = extractControllerElements(
  read("ios/GameProbe/Sources/GameProbe/Controls/ControlsManifest.swift")
);
const actions = ["$pauseMenu", "$toggleOverlay"];

const schema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  $id: "https://raw.githubusercontent.com/mateo-m/empo-app/main/docs/schemas/empo-controls.v1.schema.json",
  title: "Empo controls manifest v1",
  description:
    "Per-game touch layout and controller map for Empo (empo/controls.json). " +
    "The Swift validator in GameProbe is authoritative; this schema supports editor autocomplete.",
  type: "object",
  additionalProperties: true,
  required: ["version"],
  properties: {
    $schema: { type: "string" },
    version: {
      description: "Manifest format version. Must be exactly 1.",
      type: "number",
      const: 1
    },
    touch: { $ref: "#/$defs/touchSection" },
    controller: { $ref: "#/$defs/controllerMap" }
  },
  $defs: {
    keyCode: {
      description: "W3C KeyboardEvent.code string (SPEC §6).",
      type: "string",
      enum: keyCodes
    },
    action: {
      description: "Host action string (SPEC §8). Valid in controller maps only.",
      type: "string",
      enum: actions
    },
    controllerTarget: {
      description: "Key binding, host action, or explicit unbind (null).",
      oneOf: [{ $ref: "#/$defs/keyCode" }, { $ref: "#/$defs/action" }, { type: "null" }]
    },
    coordinate: {
      description: "Center position as a fraction of the controls zone (0.0–1.0).",
      type: "number",
      minimum: 0,
      maximum: 1
    },
    opacity: {
      description: "Control opacity (0.2–1.0).",
      type: "number",
      minimum: 0.2,
      maximum: 1
    },
    buttonSize: {
      description: "Touch button diameter in points (40–100).",
      type: "number",
      minimum: 40,
      maximum: 100
    },
    dpadSize: {
      description: "D-pad size in points (100–200).",
      type: "number",
      minimum: 100,
      maximum: 200
    },
    dpad: {
      type: "object",
      additionalProperties: true,
      required: ["x", "y"],
      properties: {
        x: { $ref: "#/$defs/coordinate" },
        y: { $ref: "#/$defs/coordinate" },
        size: { $ref: "#/$defs/dpadSize" },
        opacity: { $ref: "#/$defs/opacity" }
      }
    },
    button: {
      type: "object",
      additionalProperties: true,
      required: ["key", "x", "y"],
      properties: {
        label: {
          description: "Display label (≤ 8 characters; longer labels are truncated at runtime).",
          type: "string",
          maxLength: 8
        },
        key: { $ref: "#/$defs/keyCode" },
        x: { $ref: "#/$defs/coordinate" },
        y: { $ref: "#/$defs/coordinate" },
        size: { $ref: "#/$defs/buttonSize" },
        opacity: { $ref: "#/$defs/opacity" }
      }
    },
    touchLayout: {
      type: "object",
      additionalProperties: true,
      properties: {
        dpad: { $ref: "#/$defs/dpad" },
        buttons: {
          type: "array",
          maxItems: 16,
          items: { $ref: "#/$defs/button" }
        }
      }
    },
    touchSection: {
      type: "object",
      additionalProperties: true,
      properties: {
        portrait: { $ref: "#/$defs/touchLayout" },
        landscape: { $ref: "#/$defs/touchLayout" }
      }
    },
    controllerElement: {
      description: "SDL controller element name (SPEC §7).",
      type: "string",
      enum: controllerElements
    },
    controllerMap: {
      type: "object",
      description: "Patch overlay: only listed elements change; null unbinds.",
      propertyNames: { $ref: "#/$defs/controllerElement" },
      additionalProperties: { $ref: "#/$defs/controllerTarget" }
    }
  }
};

const outPath = path.join(repoRoot, "docs/schemas/empo-controls.v1.schema.json");
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, `${JSON.stringify(schema, null, 2)}\n`);
console.log(`Wrote ${path.relative(repoRoot, outPath)} (${keyCodes.length} key codes)`);
