# Ruby 3.0: patches

Ruby 3.0 is not in the build yet. This folder holds the patch that a Ruby 3.0
build for Pokémon SDK (PSDK) games needs.

## `load-i386-bytecode.patch`

- **Applies to**: Ruby 3.0.7, `compile.c`.
- **Problem**: a released PSDK game ships its scripts as bytecode in `Game.yarb`
  and `Data/Scripts.dat`. PSDK compiles them with a 32-bit Windows Ruby 3.0
  (`i386-mingw32`). `RubyVM::InstructionSequence.load_from_binary` raises
  `unmatched platform` on any other platform.
- **Change**: when the platform string in the file starts with `i386-` or
  `i686-`, the loader reads the 32-bit layout.

The 32-bit layout differs from the 64-bit layout in these places:

| Data | 32-bit file | Patch |
| --- | --- | --- |
| Numbers in the compact format | 32 bits, negative values not extended | Sign-extends from 32 bits |
| `true`, `nil`, `undef` | 2, 4, 6 | Maps to the 64-bit values |
| Optional argument table, local table, keyword table | 4-byte entries | Reads 4-byte entries |
| Keyword struct | 4-byte pointers | Reads the 32-bit struct |
| Range, encoding, Complex, Rational | 4-byte `long` | Reads 4-byte `long` |
| Bignum | 4-byte length, 32-bit digits | Unpacks 32-bit digits |
| Float | `double` aligned to 8 (Windows) or 4 (Linux) | Picks the alignment from the platform string |

The Ruby version check stays. Bytecode from Ruby 3.1 or later does not load.

`tools/psdk-bytecode-check/` has the test and its result.
