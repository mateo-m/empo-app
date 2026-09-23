#!/usr/bin/env bash
# Checks SFML's WAV reader against every sample format it claims to read.
#
# Builds the reader for the Mac, not for iOS. The reader has no platform
# code, so the same source file answers the same way in both places, and a
# Mac build turns a change around in a second instead of a full simulator
# run. The end-to-end run in run-test-host-ios.sh is what proves the sound
# reaches the device.
#
# Usage:
#   tools/psdk-core/test-wav-formats.sh [path/to/reference.wav]
#
# With a reference file, the test also decodes it with Apple's afconvert and
# compares the two sample by sample. Edelweiss Chronicles' title music is a
# good one:
#   .../Edelweiss_Chronicles_EN/app/audio/bgm/opening mix master 2.wav
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SFML="$ROOT/ios/Dependencies/sources/sfml"
OUT="$ROOT/build/wav-formats"

if [ ! -d "$SFML/src/SFML/Audio" ]; then
    echo "test-wav-formats: no SFML sources at $SFML" >&2
    echo "test-wav-formats: run 'git submodule update --init' first" >&2
    exit 2
fi

mkdir -p "$OUT"

echo "[wav-test] Building the reader for the Mac..."
clang++ -std=c++11 -O1 -Wall -DSFML_STATIC \
    -I"$SFML/include" -I"$SFML/src" \
    "$HERE/wav-decode.cpp" \
    "$SFML/src/SFML/Audio/SoundFileReaderWav.cpp" \
    "$SFML/src/SFML/System/Err.cpp" \
    -o "$OUT/wav-decode"

echo "[wav-test] Running the cases..."
if [ "$#" -ge 1 ]; then
    python3 "$HERE/wav-cases.py" "$OUT/wav-decode" "$OUT/cases" --reference "$1"
else
    python3 "$HERE/wav-cases.py" "$OUT/wav-decode" "$OUT/cases"
fi
