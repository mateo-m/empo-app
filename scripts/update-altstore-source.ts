#!/usr/bin/env bun
//
// Updates the AltStore source manifest for a release.
//
// Reads `altstore-source.json` at the repo root, then either prepends (or
// replaces) a version entry under `apps[0].versions[]` or removes one.
// Called from `scripts/release.sh` after the unsigned IPA is packaged so the
// recorded `size` field exactly matches the asset uploaded to GitHub
// (AltStore validates this on download and refuses to install on mismatch).
//
// AltStore's source schema requires versions to be ordered newest-first
// (per <https://faq.altstore.io/developers/make-a-source.md>). We honor
// that by inserting at index 0 instead of appending.
//
// Usage:
//   bun scripts/update-altstore-source.ts \
//     --version 0.1.1 \
//     --build 42 \
//     --size 14985878 \
//     --date 2026-05-07 \
//     --download-url https://github.com/.../Empo-0.1.1-unsigned.ipa \
//     [--description "What changed in this release."]
//
//   bun scripts/update-altstore-source.ts \
//     --version 0.1.1 \
//     --remove
//
// Re-running with a `--version` that's already present in the manifest
// replaces the existing entry (covers re-cuts of the same tag, where
// rebuilds may produce a different IPA size).

import { parseArgs } from "node:util";
import { resolve } from "node:path";

interface VersionEntry {
  version: string;
  buildVersion: string;
  date: string;
  localizedDescription?: string;
  downloadURL: string;
  size: number;
  minOSVersion?: string;
}

interface Manifest {
  apps: Array<{
    versions: VersionEntry[];
    [k: string]: unknown;
  }>;
  [k: string]: unknown;
}

const repoRoot = resolve(import.meta.dir, "..");
const defaultSourcePath = resolve(repoRoot, "altstore-source.json");

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    version: { type: "string" },
    build: { type: "string" },
    size: { type: "string" },
    date: { type: "string" },
    "download-url": { type: "string" },
    description: { type: "string" },
    remove: { type: "boolean", default: false },
    source: { type: "string", default: defaultSourcePath }
  },
  strict: true
});

// Pull every required flag through `requireFlag` so the rest of the
// script works with plain `string` locals. That drops the
// non-null-assertion ceremony at every use site and makes the
// "missing flag" error message consistent.
function requireFlag(name: string, value: string | undefined): string {
  if (value === undefined || value === "") {
    console.error(`error: missing required flag --${name}`);
    process.exit(1);
  }
  return value;
}

const version = requireFlag("version", values.version);
const remove = values.remove ?? false;
const sourcePath = values.source ?? defaultSourcePath;

const manifest = (await Bun.file(sourcePath).json()) as Manifest;

if (!manifest.apps?.[0]?.versions) {
  console.error("error: manifest is missing apps[0].versions array");
  process.exit(1);
}
const versions = manifest.apps[0].versions;

if (remove) {
  const originalLength = versions.length;
  manifest.apps[0].versions = versions.filter((v) => v.version !== version);

  if (manifest.apps[0].versions.length === originalLength) {
    console.log(`[altstore-source] no entry for v${version} in ${sourcePath}`);
    process.exit(0);
  }

  await Bun.write(sourcePath, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`[altstore-source] removed v${version} -> ${sourcePath}`);
  process.exit(0);
}

const build = requireFlag("build", values.build);
const dateString = requireFlag("date", values.date);
const downloadUrl = requireFlag("download-url", values["download-url"]);
const sizeString = requireFlag("size", values.size);
const description = values.description;

const sizeBytes = Number(sizeString);
if (!Number.isFinite(sizeBytes) || sizeBytes <= 0) {
  console.error(`error: --size must be a positive integer (got ${sizeString})`);
  process.exit(1);
}

// Reuse the previous entry's minOSVersion so the floor stays aligned
// with the project's actual deployment target without forcing the
// caller to pass it on every release.
const minOSVersion = versions[0]?.minOSVersion;

// Field order mirrors AltStore's documented version schema example
// (version, buildVersion, date, localizedDescription, downloadURL,
// size, minOSVersion). JSON.stringify preserves insertion order.
const entry: VersionEntry = {
  version,
  buildVersion: build,
  date: dateString,
  ...(description ? { localizedDescription: description } : {}),
  downloadURL: downloadUrl,
  size: sizeBytes,
  ...(minOSVersion ? { minOSVersion } : {})
};

const existingIndex = versions.findIndex((v) => v.version === version);
if (existingIndex >= 0) {
  // Re-running for the same tag (force-republish flow). Replace in
  // place rather than adding a duplicate entry that would confuse
  // AltStore's "latest" resolution.
  versions[existingIndex] = entry;
} else {
  // Newest-first ordering matters per AltStore schema docs.
  versions.unshift(entry);
}

// Two-space indent + trailing newline matches the existing file's
// formatting so diffs stay quiet across releases.
await Bun.write(sourcePath, JSON.stringify(manifest, null, 2) + "\n");

console.log(
  `[altstore-source] ${existingIndex >= 0 ? "replaced" : "prepended"} v${version} (${sizeBytes} bytes) -> ${sourcePath}`
);
