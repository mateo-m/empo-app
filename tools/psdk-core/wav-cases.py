#!/usr/bin/env python3
"""Builds WAV files for every format SFML's reader accepts or rejects, runs
the reader over each one, and compares the samples with the expected values.

The float cases are the point. A released PSDK game ships whatever its
author exported, and a 32-bit float WAV is a common export default.
Edelweiss Chronicles' title music is one, so SFML used to answer
"Failed to open WAV sound file" and the title screen stayed silent.

The scale, the rounding and the clamp all have to agree with the rest of the
world, or the sound plays at the wrong level or clips. The expected values
here come from the same three rules the reader uses, and
test-wav-formats.sh checks the reader against Apple's afconvert on a real
file as well.
"""

import argparse
import array
import struct
import subprocess
import sys

RATE = 44100

GUID_PCM = bytes([1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71])
GUID_FLOAT = bytes([3, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71])

WAVE_FORMAT_PCM = 1
WAVE_FORMAT_IEEE_FLOAT = 3
WAVE_FORMAT_EXTENSIBLE = 0xFFFE


def write_wav(path, tag, bits, channels, data, subformat=None):
    """Writes one WAV. A subformat makes the fmt chunk extensible."""
    align = channels * bits // 8
    if subformat is None:
        fmt = struct.pack("<HHIIHH", tag, channels, RATE, RATE * align, align, bits)
    else:
        fmt = struct.pack(
            "<HHIIHH", WAVE_FORMAT_EXTENSIBLE, channels, RATE, RATE * align, align, bits
        )
        fmt += struct.pack("<HHI", 22, bits, 0) + subformat
    body = (
        b"fmt "
        + struct.pack("<I", len(fmt))
        + fmt
        + b"data"
        + struct.pack("<I", len(data))
        + data
    )
    with open(path, "wb") as handle:
        handle.write(b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body)


def float_to_int16(value):
    """The reader's own three rules: scale by 32768, round, then clamp."""
    scaled = value * 32768.0 + (0.5 if value >= 0.0 else -0.5)
    if scaled > 32767.0:
        return 32767
    if scaled < -32768.0:
        return -32768
    return int(scaled)


# Zero, both full scales, past both full scales, ordinary levels, and the
# smallest step a 16-bit sample can hold.
FLOAT_VALUES = [
    0.0,
    1.0,
    -1.0,
    1.5,
    -1.5,
    0.5,
    -0.5,
    0.25,
    -0.25,
    1.0 / 32767.0,
    -1.0 / 32767.0,
    0.999969482421875,
    -0.999969482421875,
]

INT16_VALUES = [0, 32767, -32768, 16384, -16384, 1, -1]
UINT8_VALUES = [0, 255, 128, 64, 192, 129, 127]
INT24_VALUES = [0, 0x7FFFFF, 0x800000, 0x400000, 0xC00000, 0x000100, 0xFFFF00]
INT32_VALUES = [0, 0x7FFFFFFF, 0x80000000, 0x40000000, 0xC0000000, 0x00010000, 0xFFFF0000]


def signed16(value):
    return value - 0x10000 if value >= 0x8000 else value


def build_cases(folder):
    """Returns a list of (name, path, expected) and a list of (name, path,
    message) for the files the reader has to turn down."""
    accept = []
    reject = []

    float_expected = [float_to_int16(v) for v in FLOAT_VALUES]

    path = folder / "float32.wav"
    write_wav(path, WAVE_FORMAT_IEEE_FLOAT, 32, 1,
              b"".join(struct.pack("<f", v) for v in FLOAT_VALUES))
    accept.append(("32-bit float", path, float_expected))

    path = folder / "float64.wav"
    write_wav(path, WAVE_FORMAT_IEEE_FLOAT, 64, 1,
              b"".join(struct.pack("<d", v) for v in FLOAT_VALUES))
    accept.append(("64-bit float", path, float_expected))

    path = folder / "float32-extensible.wav"
    write_wav(path, WAVE_FORMAT_IEEE_FLOAT, 32, 1,
              b"".join(struct.pack("<f", v) for v in FLOAT_VALUES),
              subformat=GUID_FLOAT)
    accept.append(("32-bit float, extensible", path, float_expected))

    path = folder / "int16.wav"
    write_wav(path, WAVE_FORMAT_PCM, 16, 1,
              b"".join(struct.pack("<h", v) for v in INT16_VALUES))
    accept.append(("16-bit integer", path, list(INT16_VALUES)))

    path = folder / "int16-extensible.wav"
    write_wav(path, WAVE_FORMAT_PCM, 16, 1,
              b"".join(struct.pack("<h", v) for v in INT16_VALUES),
              subformat=GUID_PCM)
    accept.append(("16-bit integer, extensible", path, list(INT16_VALUES)))

    path = folder / "uint8.wav"
    write_wav(path, WAVE_FORMAT_PCM, 8, 1, bytes(UINT8_VALUES))
    accept.append(("8-bit unsigned", path, [(v - 128) << 8 for v in UINT8_VALUES]))

    path = folder / "int24.wav"
    write_wav(path, WAVE_FORMAT_PCM, 24, 1,
              b"".join(struct.pack("<I", v)[:3] for v in INT24_VALUES))
    accept.append(("24-bit integer", path, [signed16(v >> 8) for v in INT24_VALUES]))

    path = folder / "int32.wav"
    write_wav(path, WAVE_FORMAT_PCM, 32, 1,
              b"".join(struct.pack("<I", v) for v in INT32_VALUES))
    accept.append(("32-bit integer", path, [signed16(v >> 16) for v in INT32_VALUES]))

    path = folder / "float16.wav"
    write_wav(path, WAVE_FORMAT_IEEE_FLOAT, 16, 1, b"\x00" * 26)
    reject.append(("16-bit float", path, "Unsupported float sample size"))

    path = folder / "alaw-extensible.wav"
    write_wav(path, WAVE_FORMAT_IEEE_FLOAT, 32, 1,
              b"".join(struct.pack("<f", v) for v in FLOAT_VALUES),
              subformat=bytes([0x06] + list(GUID_PCM[1:])))
    reject.append(("extensible with an A-law subformat", path,
                   "subformat that is neither PCM nor IEEE float"))

    return accept, reject


def decode(decoder, path, count):
    """Runs the reader and returns (samples, stderr)."""
    result = subprocess.run(
        [str(decoder), str(path), str(count)], capture_output=True, check=False
    )
    samples = array.array("h")
    samples.frombytes(result.stdout)
    return list(samples), result.stderr.decode("utf-8", "replace"), result.returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("decoder", help="the built wav-decode program")
    parser.add_argument("folder", help="a folder to write the test files into")
    parser.add_argument("--reference", help="a real WAV to compare with afconvert")
    args = parser.parse_args()

    import pathlib

    folder = pathlib.Path(args.folder)
    folder.mkdir(parents=True, exist_ok=True)

    accept, reject = build_cases(folder)
    failures = 0

    for name, path, expected in accept:
        got, _, code = decode(args.decoder, path, len(expected))
        if code != 0 or got != expected:
            failures += 1
            print("FAIL %s" % name)
            print("  expected %s" % expected)
            print("  got      %s" % got)
        else:
            print("ok   %s" % name)

    for name, path, message in reject:
        got, errors, code = decode(args.decoder, path, 16)
        if code == 0:
            failures += 1
            print("FAIL %s was accepted" % name)
        elif message not in errors:
            failures += 1
            print("FAIL %s was turned down without saying why" % name)
            print("  wanted %r in %r" % (message, errors))
        else:
            print("ok   %s is turned down" % name)

    if args.reference:
        failures += compare_with_afconvert(args, folder)

    print()
    if failures:
        print("%d check(s) failed" % failures)
        return 1
    print("every check passed")
    return 0


def compare_with_afconvert(args, folder):
    """Decodes a real file both ways and counts the samples that differ.

    afconvert is Apple's own converter, so an exact match means the scale,
    the rounding and the clamp all agree with a reference outside this repo.
    """
    import pathlib

    reference = pathlib.Path(args.reference)
    print()
    print("comparing %s with afconvert" % reference.name)

    converted = folder / "afconvert-int16.wav"
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16", str(reference), str(converted)],
        capture_output=True,
        check=True,
    )

    import wave

    count = 1000000
    with wave.open(str(converted), "rb") as handle:
        theirs = array.array("h")
        theirs.frombytes(handle.readframes(count // handle.getnchannels()))

    ours, info, code = decode(args.decoder, reference, len(theirs))
    if code != 0:
        print("FAIL the reader could not open %s" % reference.name)
        print(info)
        return 1

    shared = min(len(ours), len(theirs))
    differ = sum(1 for i in range(shared) if ours[i] != theirs[i])
    worst = max((abs(ours[i] - theirs[i]) for i in range(shared)), default=0)
    print("  %d samples compared, %d differ, largest difference %d"
          % (shared, differ, worst))
    if differ:
        print("FAIL the reader and afconvert disagree")
        return 1
    print("ok   the reader matches afconvert sample for sample")
    return 0


if __name__ == "__main__":
    sys.exit(main())
