#!/usr/bin/env bash
# Apply Ruby source patches for iOS native builds in manifest order.
#
# Usage:
#   apply-ruby-patches.sh <18|19|31> <source-dir> [--patches-root DIR] [--engine DIR]
#
# Manifest: ios/Dependencies/ruby<ver>.patches.lst
#   - Blank lines and # comments are ignored.
#   - Default lines use `git apply` (paths relative to patches-root).
#   - Lines prefixed with `patch:` use `patch -p1 --fuzz=3`.
#   - `@engine@` in a path expands to the engine root (mkxp-z-apple-mobile).
#   - Trailing `*.patch` globs expand in sorted order.
set -euo pipefail

usage() {
    echo "usage: $0 <18|19|31> <source-dir> [--patches-root DIR] [--engine DIR]" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage

RUBY_VER="$1"
SOURCE_DIR="$2"
shift 2

PATCHES_ROOT="${PWD}"
ENGINE_ROOT="${PWD}/../../mkxp-z-apple-mobile"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --patches-root)
            [[ $# -ge 2 ]] || usage
            PATCHES_ROOT="$2"
            shift 2
            ;;
        --engine)
            [[ $# -ge 2 ]] || usage
            ENGINE_ROOT="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

PATCHES_ROOT="$(cd "$PATCHES_ROOT" && pwd)"
ENGINE_ROOT="$(cd "$ENGINE_ROOT" && pwd)"

MANIFEST="${PATCHES_ROOT}/ruby${RUBY_VER}.patches.lst"
[[ -f "$MANIFEST" ]] || {
    echo "error: missing patch manifest $MANIFEST" >&2
    exit 1
}
[[ -d "$SOURCE_DIR" ]] || {
    echo "error: source dir not found: $SOURCE_DIR" >&2
    exit 1
}

expand_path() {
    local raw="$1"
    raw="${raw//@engine@/${ENGINE_ROOT}}"
    if [[ "$raw" != *"*"* ]]; then
        printf '%s\n' "$raw"
        return
    fi

    local dir pattern
    if [[ "$raw" == /* ]]; then
        dir=$(dirname "$raw")
        pattern=$(basename "$raw")
    elif [[ "$raw" == "$ENGINE_ROOT"/* ]]; then
        dir=$(dirname "$raw")
        pattern=$(basename "$raw")
    else
        case "$raw" in
            */*)
                dir="${PATCHES_ROOT}/$(dirname "$raw")"
                pattern=$(basename "$raw")
                ;;
            *)
                dir="$PATCHES_ROOT"
                pattern="$raw"
                ;;
        esac
    fi

    shopt -s nullglob
    local -a matches=( "$dir"/$pattern )
    shopt -u nullglob

    if ((${#matches[@]} == 0)); then
        echo "error: glob matched no patches: $1" >&2
        exit 1
    fi

    local match
    while IFS= read -r match; do
        printf '%s\n' "$match"
    done < <(printf '%s\n' "${matches[@]}" | LC_ALL=C sort)
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

apply_unified_patch() {
    local patch_path="$1"
    [[ -f "$patch_path" ]] || {
        echo "error: patch not found: $patch_path" >&2
        exit 1
    }
    echo "Applying (patch): $(basename "$patch_path")"
    patch -p1 --fuzz=3 -i "$patch_path"
}

cd "$SOURCE_DIR"

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$line" ]] || continue

    mode="git"
    if [[ "$line" == patch:* ]]; then
        mode="patch"
        line="${line#patch:}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//')"
    fi

    while IFS= read -r patch_path; do
        if [[ "$mode" == "patch" ]]; then
            apply_unified_patch "$patch_path"
        else
            if [[ "$patch_path" != /* ]]; then
                patch_path="${PATCHES_ROOT}/${patch_path}"
            fi
            apply_git_patch "$patch_path"
        fi
    done < <(expand_path "$line")
done < "$MANIFEST"
