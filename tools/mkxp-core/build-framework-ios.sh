#!/bin/sh
# Link the mkxp-z core as one dynamic framework for one SDK.
#
# The framework is the artifact a launcher embeds, and its export list
# is what keeps the engine's three Ruby VMs and its SDL classes to
# itself. The app binary Empo ships today exports 154 _rb_ and _ruby_
# names. This dylib exports none.
#
# The link line is the app's OTHER_LDFLAGS in ios/Empo/project.yml,
# minus four entries and plus one:
#   -lSDL2main   drops. A dynamic image holds no process entry point.
#                mkxp_run_app takes its place (src/run_app.mm).
#   -larchive    drops. Only the launcher's own extractor calls it.
#   -lpng16      drops. Nothing on the line names a _png_ symbol.
#   -ldl -lpthread drop. Both live in libSystem.
#   -framework IOSurface adds. ANGLE's IOSurfaceSurfaceMtl needs it, and
#                the app link gets it from somewhere this script cannot
#                read, so it names it.
#
# Usage:
#   tools/mkxp-core/build-framework-ios.sh [--sdk iphoneos|iphonesimulator]
#
# Prerequisites:
#   cd ios/Dependencies && make -f <sdk>.make engine-halves ruby-stdlib
#   tools/fetch-angle.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$ROOT/ios/Dependencies"
ENGINE="$ROOT/mkxp-z-apple-mobile"

SDK=iphoneos
ARCH=arm64
MIN_OS=26.0

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

case "$SDK" in
    iphoneos)
        TARGET="${ARCH}-apple-ios${MIN_OS}"
        PLATFORM=iPhoneOS
        ;;
    iphonesimulator)
        TARGET="${ARCH}-apple-ios${MIN_OS}-simulator"
        PLATFORM=iPhoneSimulator
        ;;
    *)
        echo "build-framework-ios: unknown sdk $SDK" >&2
        exit 2
        ;;
esac

TREE="$DEPS/build-$SDK-$ARCH"
ANGLE="$DEPS/ANGLE/$SDK"
FW="$TREE/MkxpCore.framework"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"

for f in lib/libmkxpz-core.a lib/mkxp18-merged.o lib/mkxp19-merged.o lib/mkxp31-merged.o; do
    if [ ! -f "$TREE/$f" ]; then
        echo "build-framework-ios: $f missing." >&2
        echo "Run: cd ios/Dependencies && make -f $SDK.make engine-halves" >&2
        exit 1
    fi
done

if [ ! -d "$TREE/ruby-stdlib" ]; then
    echo "build-framework-ios: ruby-stdlib missing." >&2
    echo "Run: cd ios/Dependencies && make -f $SDK.make ruby-stdlib" >&2
    exit 1
fi

if [ ! -f "$ANGLE/lib/libANGLE_static.a" ]; then
    echo "build-framework-ios: ANGLE missing. Run: tools/fetch-angle.sh" >&2
    exit 1
fi

rm -rf "$FW"
mkdir -p "$FW/Headers"

# The export list comes from the header, so the two cannot drift. Every
# mkxp_ name followed by an open bracket is a function the bridge
# declares. A callback typedef is not, because its name is followed by a
# closing bracket.
grep -oE '\bmkxp_[A-Za-z0-9_]+\(' "$ENGINE/src/app_bridge.h" |
    sed 's/(//' | sort -u | sed 's/^/_/' >"$TREE/mkxp-core.exports"

echo "[mkxp-framework] Linking..."
"$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -install_name "@rpath/MkxpCore.framework/MkxpCore" \
    -Wl,-exported_symbols_list,"$TREE/mkxp-core.exports" \
    -L"$TREE/lib" -L"$ANGLE/lib" \
    -o "$FW/MkxpCore" \
    -Wl,-force_load,"$TREE/lib/libmkxpz-core.a" \
    "$TREE/lib/mkxp18-merged.o" \
    "$TREE/lib/mkxp19-merged.o" \
    "$TREE/lib/mkxp31-merged.o" \
    -lSDL2 -lSDL2_image -lSDL2_sound -lSDL2_ttf \
    -lfreetype -lpixman-1 -logg -lvorbis -lvorbisfile \
    -ltheora -ltheoradec -lphysfs -luchardet \
    -lz -lbz2 -liconv -lopenal -lssl -lcrypto \
    -lANGLE_static -lEGL_static -lGLESv2_static \
    -framework Foundation -framework UIKit -framework CoreFoundation \
    -framework CoreGraphics -framework CoreVideo -framework CoreAudio \
    -framework AudioToolbox -framework AVFoundation -framework Metal \
    -framework QuartzCore -framework GameController -framework CoreMotion \
    -framework IOSurface \
    -weak_framework CoreBluetooth -weak_framework CoreHaptics

echo "[mkxp-framework] Assembling the bundle..."
cp "$ENGINE/src/app_bridge.h" "$FW/Headers/"

# The engine reads these through its own bundle, which dladdr resolves
# to this framework (filesystemImplIOS.mm). A launcher embeds one
# artifact and ships no engine file of its own.
rm -rf "$FW/Assets.bundle" "$FW/Ruby"
mkdir -p "$FW/Assets.bundle/Shaders" "$FW/Assets.bundle/Fonts" \
    "$FW/Assets.bundle/Preload" "$FW/Assets.bundle/Postload"
cp "$ENGINE"/shader/*.frag "$ENGINE"/shader/*.vert "$ENGINE"/shader/*.h \
    "$FW/Assets.bundle/Shaders/"
cp "$ENGINE"/assets/liberation.ttf "$ENGINE"/assets/wqymicrohei.ttf \
    "$FW/Assets.bundle/Fonts/"
cp "$ENGINE"/assets/gamecontrollerdb.txt "$ENGINE"/assets/icon.png \
    "$ENGINE"/assets/cacert.pem "$FW/Assets.bundle/"
cp "$ENGINE"/scripts/preload/*.rb "$FW/Assets.bundle/Preload/"
cp "$ENGINE"/scripts/postload/*.rb "$FW/Assets.bundle/Postload/"
rsync -a "$TREE/ruby-stdlib/" "$FW/Ruby/"

# Which RGSS versions this core runs. The launcher reads it before it
# opens the core: a game that needs RGSS3 has to fail at import, and
# import runs off the main thread where no core is open.
#
# RGSS1 and RGSS2 run on any Ruby. RGSS3 needs the patched Ruby 3.1,
# which is what mkxp_getSupportedRGSSVersionMask answers from
# MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES (src/app_bridge.cpp). Two reads of
# that one fact, so the plist cannot drift from the core:
#
#   the binary   the patched Ruby defines
#                mkxp_syntax_transform_target_ruby_version_major, which
#                binding-util.cpp reads behind that same #ifdef. The
#                name is in the linked image or it is not.
#   the define   what the compiler saw, which is what the core answers
#                at run time.
#
# nm -a, because the merged objects hide every Ruby name, so the symbol
# is local. This script never strips the image. grep -c and not grep -q,
# so that a shell with pipefail cannot read the SIGPIPE from nm as no
# match.
PATCHED_RUBY_COUNT="$(nm -a "$FW/MkxpCore" |
    grep -c '_mkxp_syntax_transform_target_ruby_version_major$' || true)"
if [ "$PATCHED_RUBY_COUNT" -gt 0 ]; then
    PATCHED_RUBY_LINKED=yes
else
    PATCHED_RUBY_LINKED=no
fi
if grep -q 'DMKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES' "$ENGINE/tools/build-core-ios.sh"; then
    PATCHES_COMPILED_IN=yes
else
    PATCHES_COMPILED_IN=no
fi
if [ "$PATCHED_RUBY_LINKED" != "$PATCHES_COMPILED_IN" ]; then
    echo "error: the framework and the core disagree about the syntax-transform patches" >&2
    echo "       patched Ruby in $FW/MkxpCore: $PATCHED_RUBY_LINKED" >&2
    echo "       MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES in build-core-ios.sh: $PATCHES_COMPILED_IN" >&2
    echo "       EmpoCoreRGSSVersionMask would not match what the core answers." >&2
    exit 1
fi
if [ "$PATCHED_RUBY_LINKED" = yes ]; then
    RGSS_MASK=7
else
    RGSS_MASK=3
fi

# The engine source this core was linked from. Empo's Game cores
# screen shows it.
#
# A copy of the engine without .git makes git walk up to the top repo
# and answer with Empo's own tag, so ask for the gitlink in that case.
if [ -e "$ENGINE/.git" ]; then
    CORE_VERSION="$(git -C "$ENGINE" describe --tags --always --dirty 2>/dev/null || true)"
else
    CORE_VERSION="$(git -C "$ROOT" rev-parse --short HEAD:mkxp-z-apple-mobile 2>/dev/null || true)"
fi
[ -n "$CORE_VERSION" ] || CORE_VERSION=unknown

cat >"$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>MkxpCore</string>
	<key>CFBundleIdentifier</key><string>sh.mateo.empo.mkxpcore</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>MkxpCore</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
	<key>MinimumOSVersion</key><string>$MIN_OS</string>
	<key>EmpoCoreRGSSVersionMask</key><integer>$RGSS_MASK</integer>
	<key>EmpoCoreVersion</key><string>$CORE_VERSION</string>
</dict>
</plist>
EOF

# The tree keeps the framework, and Xcode only copies it. Record which
# script wrote it, so check-mkxp-framework.sh can fail when this file
# changed and nobody rebuilt the engine half.
shasum -a 256 "$ROOT/tools/mkxp-core/build-framework-ios.sh" |
    awk '{print $1}' >"$FW/.build-script-sha256"

"$ROOT/scripts/check-mkxp-framework.sh" --framework "$FW" --sdk "$SDK"
echo "[mkxp-framework] Done: $FW"
