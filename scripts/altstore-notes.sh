#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Print the AltStore update text for one version: its CHANGELOG.md
# section, the same text as the GitHub release, without the commit
# links and PR numbers. AltStore shows this text as plain text, so it
# has no Markdown.
#
# Usage: scripts/altstore-notes.sh <version> [changelog-path]
set -euo pipefail

VERSION="${1:?usage: $0 <version> [changelog-path]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG_PATH="${2:-$ROOT/CHANGELOG.md}"

"$ROOT/scripts/extract-changelog.sh" "$VERSION" "$CHANGELOG_PATH" | perl -CSD -e '
    my %heading = (
        "Highlights" => "Highlights",
        "Features" => "New",
        "Bug Fixes" => "Fixed",
        "Performance" => "Faster",
        "UI" => "Look and feel",
    );
    my @order = ("Highlights", "New", "Fixed", "Faster", "Look and feel", "Other changes");
    my ($group, %items, %seen);
    while (<STDIN>) {
        chomp;
        if (/^### (.+)/) {
            $group = $heading{$1} // "Other changes";
            next;
        }
        next unless defined $group && s/^- //;
        s/ \(\[`[0-9a-f]+`\]\([^)]*\)\)$//;
        s/ \((?:[\w.-]+\/[\w.-]+)?\x23\d+\)//g;
        s/`//g;
        push @{ $items{$group} }, $_ unless $seen{$_}++;
    }
    print join "\n\n", map { join "\n", $_, map { "\x{2022} $_" } @{ $items{$_} } }
        grep { $items{$_} } @order;
'
