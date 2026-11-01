# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# The steps that cores/*/build-framework-ios.sh and
# cores/*/check-framework.sh share. Source it.

# The callers read the variables that these functions set.
# shellcheck disable=SC2034

# For a manual run. Xcode gives the deployment target of the target that
# runs the script.
DEFAULT_MIN_OS=26.0
ARCH=arm64

# Runs the calling script again under lockf. Xcode and a script can link
# at the same time, and the second run then finds the framework in place.
# Usage: run_locked <lock file> "$0" "$@"
run_locked() {
    lock="$1"
    shift
    if [ "${EMPO_FRAMEWORK_LOCK:-}" != "$lock" ]; then
        EMPO_FRAMEWORK_LOCK="$lock" exec lockf -k "$lock" "$@"
    fi
}

# Reads "--sdk <sdk>" and sets SDK, TARGET, PLATFORM, MIN_OS and
# MIN_OS_KEY.
parse_sdk() {
    SDK=iphoneos
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --sdk)
                SDK="$2"
                shift 2
                ;;
            *)
                echo "build-framework-ios: unknown argument $1" >&2
                exit 2
                ;;
        esac
    done
    MIN_OS_KEY=MinimumOSVersion
    case "$SDK" in
        iphoneos)
            MIN_OS="${IPHONEOS_DEPLOYMENT_TARGET:-$DEFAULT_MIN_OS}"
            TARGET="$ARCH-apple-ios$MIN_OS"
            PLATFORM=iPhoneOS
            ;;
        iphonesimulator)
            MIN_OS="${IPHONEOS_DEPLOYMENT_TARGET:-$DEFAULT_MIN_OS}"
            TARGET="$ARCH-apple-ios$MIN_OS-simulator"
            PLATFORM=iPhoneSimulator
            ;;
        macosx)
            MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-$DEFAULT_MIN_OS}"
            TARGET="$ARCH-apple-macos$MIN_OS"
            PLATFORM=MacOSX
            MIN_OS_KEY=LSMinimumSystemVersion
            ;;
        *)
            echo "build-framework-ios: unknown sdk $SDK" >&2
            exit 2
            ;;
    esac
}

# The LC_BUILD_VERSION platform number of an SDK.
platform_number() {
    case "$1" in
        iphonesimulator) echo 7 ;;
        macosx) echo 1 ;;
        *) echo 2 ;;
    esac
}

# The folder of a framework's resources. A macOS framework keeps its
# binary and resources in Versions/A, with links at the top. codesign
# refuses the flat iOS layout on macOS.
resources_dir() {
    if [ "$2" = macosx ]; then
        echo "$1/Resources"
    else
        echo "$1"
    fi
}

# Empties the framework folder and sets BIN_DIR and RES.
# Usage: start_framework <framework>
start_framework() {
    if [ "$SDK" = macosx ]; then
        BIN_DIR="$1/Versions/A"
    else
        BIN_DIR="$1"
    fi
    RES="$(resources_dir "$BIN_DIR" "$SDK")"
    rm -rf "$1"
    mkdir -p "$RES"
}

# Writes the Info.plist, the license notices and the privacy manifest,
# then the macOS links.
# Usage: finish_framework <framework> <name> <bundle id> <core version>
#   <licenses.json> [extra plist keys]
finish_framework() {
    # The licenses screen reads licenses.json (LicenseEntry.inThisBuild).
    cp "$5" "$RES/"
    cp "$ROOT/cores/PrivacyInfo.xcprivacy" "$RES/"
    cat >"$RES/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$2</string>
	<key>CFBundleIdentifier</key><string>$3</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$2</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
	<key>$MIN_OS_KEY</key><string>$MIN_OS</string>
	<key>EmpoCoreVersion</key><string>$4</string>${6:-}
</dict>
</plist>
PLIST
    if [ "$SDK" = macosx ]; then
        ln -s A "$1/Versions/Current"
        ln -s "Versions/Current/$2" "$1/$2"
        ln -s Versions/Current/Resources "$1/Resources"
    fi
}
