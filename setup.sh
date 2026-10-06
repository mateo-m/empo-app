#!/bin/sh
# Setup script for Empo development.
# Run this once after cloning the repository if you want a one-shot
# bootstrap for local tools + hook install.

set -e

echo "Installing repo-managed git hooks via LeftHook..."
if ! command -v bun >/dev/null 2>&1; then
    echo "Missing required tool: bun" >&2
    exit 1
fi
bun install
echo "Git hooks configured."

echo "Verifying required hook tools..."
for tool in swift-format swiftlint clang-format bun shfmt shellcheck; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool" >&2
        exit 1
    fi
done
echo "All required hook tools are installed."

echo "Done."
