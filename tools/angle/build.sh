#!/bin/sh
# Builds the ANGLE prebuilt that tools/fetch-angle.sh downloads, from
# source, with the patches in this folder.
#
# Usage:
#   tools/angle/build.sh [work-dir] [out-dir]
#
# out-dir gets iphoneos/{include,lib} and iphonesimulator/{include,lib},
# the layout of ios/Dependencies/ANGLE.
set -eu

ANGLE_COMMIT=d81d29e166b6af1181f06e56c916c06676dd6ad1
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-${TMPDIR:-/tmp}/empo-angle}"
DEST="${2:-$HERE/../../ios/Dependencies/ANGLE}"
SRC="$WORK/angle"

if [ ! -d "$SRC/.git" ]; then
    git init -q "$SRC"
    git -C "$SRC" fetch -q --depth 1 https://chromium.googlesource.com/angle/angle "$ANGLE_COMMIT"
    git -C "$SRC" checkout -q FETCH_HEAD
    for p in "$HERE"/*.patch; do git -C "$SRC" apply "$p"; done
fi

[ -d "$WORK/depot_tools" ] ||
    git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"

export PATH="$WORK/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
cd "$SRC"
if [ ! -f .gclient ]; then
    python3 scripts/bootstrap.py
    echo "target_os = ['ios']" >>.gclient
fi
gclient sync --no-history --shallow -j8

# The clang that ANGLE pins cannot read the libc++ headers of a newer
# iOS SDK, so build with Xcode's clang. Xcode has no llvm-ar, and gn
# wants both tools in one folder, so take llvm-ar from ANGLE's clang.
XCODE_CLANG="$(dirname "$(dirname "$(xcrun -f clang)")")"
TOOLCHAIN="$WORK/toolchain"
mkdir -p "$TOOLCHAIN/bin"
ln -sfn "$XCODE_CLANG/lib" "$TOOLCHAIN/lib"
ln -sf "$XCODE_CLANG/bin/clang" "$XCODE_CLANG/bin/clang++" "$TOOLCHAIN/bin/"
ln -sf "$SRC/third_party/llvm-build/Release+Asserts/bin/llvm-ar" "$TOOLCHAIN/bin/llvm-ar"
CLANG_VERSION="$(find "$XCODE_CLANG/lib/clang" -mindepth 1 -maxdepth 1 -exec basename {} \; | grep -E '^[0-9]+$' | sort -n | tail -1)"

ARGS="target_os=\"ios\" target_cpu=\"arm64\" ios_deployment_target=\"16.0\"
is_debug=false is_component_build=false symbol_level=1
use_custom_libcxx=false ios_enable_code_signing=false
clang_base_path=\"$TOOLCHAIN\" clang_version=\"$CLANG_VERSION\"
clang_use_chrome_plugins=false treat_warnings_as_errors=false
angle_enable_metal=true angle_enable_vulkan=false angle_enable_gl=false
angle_enable_null=false angle_enable_wgpu=false angle_enable_swiftshader=false
angle_has_frame_capture=false angle_build_tests=false build_angle_deqp_tests=false"

GN="$SRC/buildtools/mac/gn"
for pair in iphoneos:ios-arm64: iphonesimulator:sim-arm64:simulator; do
    sdk="${pair%%:*}"
    rest="${pair#*:}"
    out="$SRC/out/${rest%%:*}"
    env="${rest#*:}"
    "$GN" gen "$out" --args="$ARGS target_environment=\"${env:-device}\""
    third_party/ninja/ninja -C "$out" libEGL_static libGLESv2_static

    # gn makes thin archives of the libraries alone. The app links three
    # full archives: libEGL_static, libGLESv2_static, and libANGLE_static
    # with every other object that they need.
    (cd "$out" && {
        "$GN" desc . //:libEGL_static deps --all
        echo //:libEGL_static
    } | sort -u |
        while read -r target; do
            label="${target%%(*}"
            dir="${label%%:*}"
            dir="${dir#//}"
            name="${label##*:}"
            ninja_file="obj/${dir:+$dir/}$name.ninja"
            [ -f "$ninja_file" ] && sed -n 's/^build \([^:]*\.o\): .*/\1/p' "$ninja_file"
        done | sort -u >objects.txt)
    grep '^obj/libGLESv2_static/' "$out/objects.txt" >"$out/glesv2-objects.txt"
    grep '^obj/libEGL_static/' "$out/objects.txt" >"$out/egl-objects.txt"
    grep -v -e '^obj/libGLESv2_static/' -e '^obj/libEGL_static/' "$out/objects.txt" >"$out/angle-objects.txt"

    rm -rf "${DEST:?}/$sdk"
    mkdir -p "$DEST/$sdk/lib"
    cp -R include "$DEST/$sdk/include"
    find "$DEST/$sdk/include" \( -name "*.gn" -o -name OWNERS -o -name DIR_METADATA \) -delete
    for lib in ANGLE GLESv2 EGL; do
        list="$(echo "$lib" | tr '[:upper:]' '[:lower:]')-objects.txt"
        (cd "$out" && xcrun libtool -static -no_warning_for_no_symbols \
            -o "$DEST/$sdk/lib/lib${lib}_static.a" -filelist "$list")
    done
done
echo "ANGLE $ANGLE_COMMIT built into $DEST"
