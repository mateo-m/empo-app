#!/usr/bin/env python3
"""Rename loose game files to the spelling the game's scripts use.

iOS opens files case-sensitively. Windows and macOS do not, so a released
PSDK game can ship Yuki_Transition_Circular.txt and ask for
yuki_transition_circular.txt. Edelweiss Chronicles does that for two
shader files.

A second name under the other spelling is not an option. The staging
volume on a Mac is case-insensitive, so both names are the same file
there and the link or copy fails. A rename works on both volumes,
because APFS accepts a case-only rename.

The spelling to use comes from the game itself. Data/Scripts.dat holds
the compiled scripts, and every path literal survives in the bytecode as
a plain string. This reads those literals and renames the file on disk
when a literal points to it through a different spelling.

This belongs in Empo's import pipeline. The test harness calls it from
run-test-host-ios.sh.

Usage: normalize-case.py <game-dir>
"""
import os
import re
import sys
import zlib

# The folders a game reads loose files from. The pattern starts at one of
# these names, because the bytecode stores each string with a length byte
# in front and that byte is often a letter. A pattern that only looks for
# a slash swallows it and turns graphics/x into Ugraphics/x.
LOOSE_ROOTS = ('graphics', 'audio', 'Fonts', 'plugins', 'pokemonsdk')

PATH_PATTERN = re.compile(
    r'(?:' + '|'.join(LOOSE_ROOTS) + r')'
    r'(?:/[A-Za-z0-9_.-]+)+\.[a-z]{2,4}(?![A-Za-z0-9_])'
)


def script_path_literals(game):
    """Every path-looking string in the compiled scripts."""
    blob = zlib.decompress(open(os.path.join(game, 'Data', 'Scripts.dat'), 'rb').read())
    out = set()
    for run in re.findall(rb'[\x20-\x7e]{4,200}', blob):
        out.update(PATH_PATTERN.findall(run.decode()))
    return out


def resolve(game, path):
    """Walk path one name at a time, matching without case.

    Returns the spelling on disk, or None. os.path.exists cannot answer
    this on a case-insensitive volume, so every step reads the directory.
    """
    current = game
    found = []
    for want in path.split('/'):
        try:
            entries = os.listdir(current)
        except OSError:
            return None
        if want in entries:
            hit = want
        else:
            matches = [e for e in entries if e.lower() == want.lower()]
            if len(matches) != 1:
                return None
            hit = matches[0]
        found.append(hit)
        current = os.path.join(current, hit)
    return '/'.join(found)


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: normalize-case.py <game-dir>')
    game = sys.argv[1]

    renamed = 0
    for wanted in sorted(script_path_literals(game)):
        on_disk = resolve(game, wanted)
        if on_disk is None or on_disk == wanted:
            continue
        # Only the base name is safe to rename. A folder rename would
        # break every other file under it that already reads correctly.
        if os.path.dirname(on_disk) != os.path.dirname(wanted):
            print(f'  folder case differs, left alone: {on_disk} != {wanted}')
            continue
        os.rename(os.path.join(game, on_disk), os.path.join(game, wanted))
        print(f'  {on_disk} -> {os.path.basename(wanted)}')
        renamed += 1
    print(f'[normalize-case] renamed {renamed} files')


main()
