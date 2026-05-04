#!/bin/sh
# generate-ruby-unexports.sh
#
# Produce a "do not export" symbol list for a Ruby static archive
# (libruby.<ver>-static.a + libruby.<ver>-ext.a). Used by the
# multi-Ruby build pipeline (Phase D in MULTI_RUBY_PLAN.md) to
# demote every Ruby-defined symbol to private-extern when the
# archive is merged via `ld -r`. With Ruby's symbols hidden,
# multiple Ruby versions can coexist in one binary without the
# `_rb_define_class` etc. clashing on link.
#
# Usage:
#   generate-ruby-unexports.sh <static.a> <ext.a> > unexports.txt
#
# Then in the build pipeline:
#   ld -r -arch arm64 \
#       -platform_version ios-simulator <min> <sdk> \
#       -syslibroot $SDK \
#       -unexported_symbols_list unexports.txt \
#       libruby.<ver>-static.a libruby.<ver>-ext.a binding-mri-<ver>.o ... \
#       -o ruby<ver>-merged.o
#
# Verified on libruby.3.0-static.a + libruby.3.0-ext.a producing
# 2675 symbols, all of which become local in the merged .o.
#
# nm flags:
#   -g  globally-defined symbols
#   -U  hide undefined references (we only care about defined)
#
# AWK pattern keeps T (text/code), D (data), S (small uninit BSS),
# R (read-only data) symbols. Ignores 'U' (undefined) and
# weak/common (W/V/C) which generally either come from libc
# (don't rename) or behave correctly across the merge anyway.

set -e

if [ $# -lt 1 ]; then
    echo "usage: $0 <archive.a> [<archive.a>...]" >&2
    exit 2
fi

for archive in "$@"; do
    if [ ! -f "$archive" ]; then
        echo "$0: archive not found: $archive" >&2
        exit 1
    fi
    nm -gU "$archive" 2>/dev/null
done | awk '/^[0-9a-f]+ [TDSR] /{print $3}' | sort -u
