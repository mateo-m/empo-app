#!/usr/bin/env bash
# Apply SDL2 source patches for iOS native builds in manifest order.
#
# Usage:
#   apply-sdl-patches.sh <source-dir> [--patches-root DIR]
#
# Manifest: ios/Dependencies/sdl2.patches.lst
set -euo pipefail

usage() {
    echo "usage: $0 <source-dir> [--patches-root DIR]" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage

SOURCE_DIR="$1"
shift

PATCHES_ROOT="${PWD}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --patches-root)
            [[ $# -ge 2 ]] || usage
            PATCHES_ROOT="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

PATCHES_ROOT="$(cd "$PATCHES_ROOT" && pwd)"
MANIFEST="${PATCHES_ROOT}/sdl2.patches.lst"

[[ -f "$MANIFEST" ]] || {
    echo "error: missing patch manifest $MANIFEST" >&2
    exit 1
}
[[ -d "$SOURCE_DIR" ]] || {
    echo "error: source dir not found: $SOURCE_DIR" >&2
    exit 1
}

apply_git_patch() {
    local patch_path="$1"
    [[ -f "$patch_path" ]] || {
        echo "error: patch not found: $patch_path" >&2
        exit 1
    }
    echo "Applying (git): $(basename "$patch_path")"
    git apply "$patch_path"
}

cd "$SOURCE_DIR"

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$line" ]] || continue

    patch_path="${PATCHES_ROOT}/${line}"
    apply_git_patch "$patch_path"
done < "$MANIFEST"
