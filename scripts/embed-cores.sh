#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Copies the game cores that cores/cores.sh names into the app's
# Frameworks folder. Runs from an Xcode build phase of the iOS app and of
# the Mac app.
#
# The app links none of the cores. It opens one of them with dlopen when
# the user picks a game, so a copy phase, not a linked dependency: a
# second core must not bind to the first core's names.
#
# The app reads the bundle to find out which cores it got
# (GameCores.inThisBuild), and refuses a game that it cannot run.

set -euo pipefail

TREE="${PROJECT_DIR}/../Dependencies/build-${PLATFORM_NAME}-arm64"
DEST="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "$DEST"
# shellcheck source=cores/cores.sh
. "${PROJECT_DIR}/../../cores/cores.sh"
for CORE in ${EMPO_CORES}; do
    CORE_SRC="$TREE/$CORE.framework"
    case "$CORE" in
        MkxpCore) HOW="cores/mkxp/build-framework-ios.sh --sdk ${PLATFORM_NAME}" ;;
        Psdk*Core) HOW="cores/psdk/build-framework-ios.sh --sdk ${PLATFORM_NAME}" ;;
        MvmzCore)
            HOW="build the MvmzCore target"
            CORE_SRC="${BUILT_PRODUCTS_DIR}/$CORE.framework"
            ;;
        *)
            echo "error: EMPO_CORES names an unknown core: $CORE" >&2
            exit 1
            ;;
    esac
    if [ ! -d "$CORE_SRC" ]; then
        echo "error: $CORE_SRC missing - run: $HOW" >&2
        exit 1
    fi
    # An archive builds MvmzCore as a link into UninstalledProducts.
    # The "/" at the end makes rsync copy what the link points to.
    rsync -a --delete "$CORE_SRC/" "$DEST/$CORE.framework/"
    # A nested framework carries its own signature. The app's own
    # signing step does not reach inside it, so sign it here, the way
    # Xcode's Embed Frameworks phase does.
    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
            --preserve-metadata=identifier,entitlements,flags \
            --timestamp=none "$DEST/$CORE.framework"
    fi
done
# An incremental build keeps the framework folder from the last build,
# so remove a core that this build does not ship. Older builds shipped
# PsdkCore.
for CORE in $EMPO_ALL_CORES PsdkCore; do
    case " ${EMPO_CORES} " in
        *" $CORE "*) continue ;;
    esac
    rm -rf "${DEST:?}/$CORE.framework"
done
