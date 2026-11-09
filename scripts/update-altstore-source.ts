#!/usr/bin/env bun
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

// Writes one release into altstore-source.json. A release that is already
// there gets the new values.
//
// Usage:
//   bun scripts/update-altstore-source.ts \
//     --version 0.1.1 --build 42 --min-os-version 26.0 \
//     --size 14985878 --date 2026-05-07 \
//     --download-url https://github.com/mateo-m/empo-app/releases/download/v0.1.1/Empo-ios.ipa \
//     [--description "What changed in this release."]

import { parseArgs } from "node:util";
import { resolve } from "node:path";

interface VersionEntry {
  version: string;
  buildVersion: string;
  date: string;
  localizedDescription?: string;
  downloadURL: string;
  size: number;
  minOSVersion: string;
}

interface Manifest {
  apps: Array<{
    versions: VersionEntry[];
    [k: string]: unknown;
  }>;
  [k: string]: unknown;
}

const sourcePath = resolve(import.meta.dir, "..", "altstore-source.json");

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    version: { type: "string" },
    build: { type: "string" },
    "min-os-version": { type: "string" },
    size: { type: "string" },
    date: { type: "string" },
    "download-url": { type: "string" },
    description: { type: "string" }
  },
  strict: true
});

function requireFlag(name: string, value: string | undefined): string {
  if (value === undefined || value === "") {
    console.error(`error: missing required flag --${name}`);
    process.exit(1);
  }
  return value;
}

const version = requireFlag("version", values.version);
const sizeString = requireFlag("size", values.size);
const size = Number(sizeString);
if (!Number.isInteger(size) || size <= 0) {
  console.error(`error: --size must be a positive integer (got ${sizeString})`);
  process.exit(1);
}

const manifest = (await Bun.file(sourcePath).json()) as Manifest;
const versions = manifest.apps?.[0]?.versions;
if (!versions) {
  console.error("error: the manifest has no apps[0].versions array");
  process.exit(1);
}

// AltStore refuses to install an IPA whose size is not the size here.
// It also wants the newest version first, and keys in this order.
const entry: VersionEntry = {
  version,
  buildVersion: requireFlag("build", values.build),
  date: requireFlag("date", values.date),
  ...(values.description ? { localizedDescription: values.description } : {}),
  downloadURL: requireFlag("download-url", values["download-url"]),
  size,
  minOSVersion: requireFlag("min-os-version", values["min-os-version"])
};

const existingIndex = versions.findIndex((v) => v.version === version);
if (existingIndex >= 0) {
  versions[existingIndex] = entry;
} else {
  versions.unshift(entry);
}

await Bun.write(sourcePath, JSON.stringify(manifest, null, 2) + "\n");

console.log(
  `[altstore-source] ${existingIndex >= 0 ? "replaced" : "added"} v${version} (${size} bytes) -> ${sourcePath}`
);
