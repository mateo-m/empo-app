// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

const path = new URL("../.github/workflows/ci.yml", import.meta.url);
const workflow = Bun.YAML.parse(await Bun.file(path).text()) as {
  jobs: Record<string, { needs?: string | string[] }>;
};
const needs = [workflow.jobs["ci-summary"]?.needs ?? []].flat();
const missing = Object.keys(workflow.jobs).filter((job) => job !== "ci-summary" && !needs.includes(job));
if (missing.length > 0) {
  console.error(`error: the CI job in ci.yml does not need: ${missing.join(", ")}`);
  process.exit(1);
}
