#!/usr/bin/env bun
//
// Generates docs/schemas/empo-controls.v1.schema.json from GameProbe source.
// The Swift model is the single source of truth: key codes, controller
// elements, actions and movement styles are all read out of it, so the
// published schema cannot drift from the validator.
//
// Usage:
//   bun tools/generate-controls-schema.ts

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

interface EmpoActionEntry {
  id: string;
  touchValid: boolean;
}

function read(relPath: string): string {
  return fs.readFileSync(path.join(repoRoot, relPath), "utf8");
}

function extractKeyCodes(swift: string): string[] {
  const codes = [...swift.matchAll(/Entry\(code: "([^"]+)"/g)].map((match) => match[1]!);
  if (codes.length === 0) {
    throw new Error("no key codes found in KeyCodeTable.swift");
  }
  return codes;
}

function extractControllerElements(swift: string): string[] {
  const block = swift.match(/allElements: \[String\] = \[([\s\S]*?)\]/);
  if (!block) {
    throw new Error("controller element list not found in ControlsManifest.swift");
  }
  const elements = [...block[1]!.matchAll(/"([^"]+)"/g)].map((match) => match[1]!);
  if (elements.length === 0) {
    throw new Error("no controller elements found");
  }
  return elements;
}

function extractActions(swift: string): EmpoActionEntry[] {
  const block = swift.match(/all: \[EmpoAction\] = \[([\s\S]*?)\n    \]/);
  if (!block) {
    throw new Error("action table not found in EmpoAction.swift");
  }
  const constants = new Map(
    [...swift.matchAll(/static let (\w+) = "(\$\w+)"/g)].map((match) => [match[1]!, match[2]!]),
  );
  const actions = [...block[1]!.matchAll(/id: (\w+)[\s\S]*?touchValid: (true|false)/g)].map(
    (match): EmpoActionEntry => ({
      id: constants.get(match[1]!) ?? "",
      touchValid: match[2] === "true",
    }),
  );
  if (actions.length === 0 || actions.some((action) => action.id === "")) {
    throw new Error("no actions found in EmpoAction.swift");
  }
  return actions;
}

function extractMovementStyles(swift: string): string[] {
  const block = swift.match(/enum MovementStyle[^{]*\{([\s\S]*?)\n\}/);
  if (!block) {
    throw new Error("MovementStyle enum not found in ControlsManifest.swift");
  }
  const styles = [...block[1]!.matchAll(/case (\w+)/g)].map((match) => match[1]!);
  if (styles.length === 0) {
    throw new Error("no movement styles found");
  }
  return styles;
}

const manifestSwift = read("ios/GameProbe/Sources/GameProbe/Controls/ControlsManifest.swift");
const keyCodes = extractKeyCodes(read("ios/GameProbe/Sources/GameProbe/Controls/KeyCodeTable.swift"));
const controllerElements = extractControllerElements(manifestSwift);
const actionTable = extractActions(read("ios/GameProbe/Sources/GameProbe/Controls/EmpoAction.swift"));
const actions = actionTable.map((action) => action.id);
const touchActions = actionTable.filter((action) => action.touchValid).map((action) => action.id);
const movementStyles = extractMovementStyles(manifestSwift);

const schema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  $id: "https://raw.githubusercontent.com/mateo-m/empo-app/main/docs/schemas/empo-controls.v1.schema.json",
  title: "Empo controls manifest v1",
  description:
    "Per-game touch layout and input bindings for Empo (empo/controls.json). " +
    "The Swift validator in GameProbe is authoritative. This schema supports editor autocomplete.",
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
    bindings: { $ref: "#/$defs/bindingMap" },
    controller: {
      description: "First name of the bindings section. Still valid, but bindings wins if both appear.",
      $ref: "#/$defs/bindingMap"
    }
  },
  $defs: {
    keyCode: {
      description: "W3C KeyboardEvent.code string (SPEC section 6).",
      type: "string",
      enum: keyCodes
    },
    action: {
      description:
        "Host action string (SPEC section 8). Valid in the bindings map. " +
        "the touch-valid subset also works in actionButtons.",
      type: "string",
      enum: actions
    },
    touchAction: {
      description:
        "Actions a touch actionButton can bind. $toggleTouchControls is controller-only.",
      type: "string",
      enum: touchActions
    },
    bindingTarget: {
      description:
        "Key binding, controller element, host action, or explicit unbind (null). " +
        "An element target is for key sources only: the key then takes that button's binding.",
      oneOf: [
        { $ref: "#/$defs/keyCode" },
        { $ref: "#/$defs/controllerElement" },
        { $ref: "#/$defs/action" },
        { type: "null" }
      ]
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
        opacity: { $ref: "#/$defs/opacity" },
        style: {
          description:
            "Movement control style. stick draws a joystick with the same key mapping.",
          type: "string",
          enum: movementStyles
        }
      }
    },
    actionButton: {
      type: "object",
      additionalProperties: true,
      required: ["action", "x", "y"],
      properties: {
        action: { $ref: "#/$defs/touchAction" },
        x: { $ref: "#/$defs/coordinate" },
        y: { $ref: "#/$defs/coordinate" },
        size: { $ref: "#/$defs/buttonSize" },
        opacity: { $ref: "#/$defs/opacity" }
      }
    },
    button: {
      type: "object",
      additionalProperties: true,
      required: ["key", "x", "y"],
      properties: {
        label: {
          description: "Display label of 8 characters or fewer. Longer labels are cut at runtime.",
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
          maxItems: 21,
          items: { $ref: "#/$defs/button" }
        },
        actionButtons: {
          description:
            "Buttons that trigger Empo actions. The 21-per-orientation cap counts " +
            "buttons and actionButtons together. The runtime validator enforces the " +
            "combined cap.",
          type: "array",
          maxItems: 21,
          items: { $ref: "#/$defs/actionButton" }
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
      description: "SDL controller element name (SPEC section 7).",
      type: "string",
      enum: controllerElements
    },
    bindingSource: {
      description:
        "A controller element (SPEC section 7) or a keyboard key (SPEC section 6). " +
        "A pad in keyboard mode reaches iOS as a keyboard, so its buttons are keys here.",
      type: "string",
      enum: [...controllerElements, ...keyCodes]
    },
    bindingMap: {
      type: "object",
      description: "Patch overlay: only listed sources change. A null value unbinds.",
      propertyNames: { $ref: "#/$defs/bindingSource" },
      additionalProperties: { $ref: "#/$defs/bindingTarget" }
    }
  }
};

const outPath = path.join(repoRoot, "docs/schemas/empo-controls.v1.schema.json");
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, `${JSON.stringify(schema, null, 2)}\n`);
console.log(`Wrote ${path.relative(repoRoot, outPath)} (${keyCodes.length} key codes)`);
