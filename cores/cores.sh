# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# The game cores of Empo. Source it.
#
# EMPO_CORES set by the caller builds and ships only the cores it names:
#   xcodebuild ... EMPO_CORES=Psdk30Core

# The callers read the variables that this file sets.
# shellcheck disable=SC2034

EMPO_ALL_CORES="MkxpCore Psdk25Core Psdk30Core Psdk32Core Psdk33Core MvmzCore"
EMPO_CORES="${EMPO_CORES:-$EMPO_ALL_CORES}"
