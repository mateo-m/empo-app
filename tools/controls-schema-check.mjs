#!/usr/bin/env node
/**
 * Validates the published controls schema against the example (pass) and a V010 typo (fail).
 * Run: node tools/controls-schema-check.mjs
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv from "ajv";
import addFormats from "ajv-formats";
import draft2020 from "ajv/dist/2020.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");

const schemaPath = path.join(repoRoot, "docs/schemas/empo-controls.v1.schema.json");
const examplePath = path.join(repoRoot, "docs/examples/empo-controls-example.json");
const typoPath = path.join(repoRoot, "tools/fixtures/controls-v010-typo.json");

function loadJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

const ajv = new draft2020({ allErrors: true, strict: false });
addFormats(ajv);

const schema = loadJson(schemaPath);
const validate = ajv.compile(schema);

function check(label, filePath, shouldPass) {
  const data = loadJson(filePath);
  const ok = validate(data);
  const rel = path.relative(repoRoot, filePath);
  if (shouldPass && ok) {
    console.log(`PASS ${label}: ${rel}`);
    return;
  }
  if (!shouldPass && !ok) {
    console.log(`PASS ${label}: ${rel} (rejected as expected)`);
    for (const err of validate.errors ?? []) {
      console.log(`  ${err.instancePath || "/"} ${err.message}`);
    }
    return;
  }
  console.error(`FAIL ${label}: ${rel}`);
  if (validate.errors) {
    for (const err of validate.errors) {
      console.error(`  ${err.instancePath || "/"} ${err.message}`);
    }
  }
  process.exit(1);
}

check("example accepts", examplePath, true);
check("V010 typo rejects", typoPath, false);
console.log("controls schema check OK");
