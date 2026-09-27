# Ruby 2.5: patches

Psdk25Core, the core for Pokémon SDK (PSDK) games from December 2019 to about
March 2021, uses Ruby 2.5. This folder holds the patches of that Ruby.

## `ios.patch`

- **Applies to**: Ruby 2.5.9.
- **Problem**: Ruby 2.5 does not cross-compile for iOS.
- **Change**: `configure.ac`, `dir.c` and `process.c` get the same iOS changes
  as in Ruby 3.0. `template/configure-ext.mk.tmpl` quotes `MINIRUBY` in the
  make flags, because the cross build puts spaces in that command.

## `load-i386-bytecode.patch`

- **Applies to**: Ruby 2.5.9, `compile.c`.
- **Problem**: a PSDK release of that time ships its scripts as bytecode that a
  32-bit Windows Ruby 2.5 compiled. A 64-bit Ruby cannot read that layout.
- **Change**: when the file comes from a 32-bit x86 Ruby, the loader reads the
  4-byte fields and sign-extends them. `true`, `nil` and `undef` have the values
  2, 4 and 6 in that layout, and the loader maps them to the 64-bit values.
