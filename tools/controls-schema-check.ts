#!/usr/bin/env bun
//
// Validates the published controls schema against the documented
// example (must pass) and a fixture with a mistyped key code (must
// fail). Run it after regenerating the schema.
//
// Usage:
//   bun tools/controls-schema-check.ts

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import addFormats from "ajv-formats";
import Ajv2020 from "ajv/dist/2020.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const schemaPath = path.join(repoRoot, "docs/schemas/empo-controls.v1.schema.json");
const examplePath = path.join(repoRoot, "docs/examples/controls.json");
const typoPath = path.join(repoRoot, "tools/fixtures/controls-v010-typo.json");

function loadJson(filePath: string): unknown {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validate = ajv.compile(loadJson(schemaPath) as object);

function check(label: string, filePath: string, shouldPass: boolean): void {
  const ok = validate(loadJson(filePath));
  const relative = path.relative(repoRoot, filePath);

  if (ok === shouldPass) {
    const outcome = shouldPass ? "" : " (rejected as expected)";
    console.log(`PASS ${label}: ${relative}${outcome}`);
    if (!shouldPass) {
      for (const error of validate.errors ?? []) {
        console.log(`  ${error.instancePath || "/"} ${error.message}`);
      }
    }
    return;
  }

  console.error(`FAIL ${label}: ${relative}`);
  for (const error of validate.errors ?? []) {
    console.error(`  ${error.instancePath || "/"} ${error.message}`);
  }
  process.exit(1);
}

check("example accepts", examplePath, true);
check("V010 typo rejects", typoPath, false);
console.log("controls schema check OK");
