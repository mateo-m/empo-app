# LZMA SDK decoder

These files come from the LZMA SDK in 7-Zip **26.06**
(https://github.com/ip7z/7zip, tag `26.06`, folder `C`), with no changes.
Igor Pavlov put them in the public domain.

`include/` holds the two headers that Swift imports. The other files
stay next to `LzmaDec.c`.

`InnoSetupArchive` uses the decoder to read the LZMA1 streams of
Inno Setup installers. To upgrade, copy the same five files from the
new tag and update the version above.
