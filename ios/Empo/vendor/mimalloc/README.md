# mimalloc

Vendored from mimalloc **v3.5.4** (https://github.com/microsoft/mimalloc,
tag `v3.5.4`), MIT, see `LICENSE`.

The game process uses it as its malloc zone, on the block of memory that
the app lends it (`GameProcess/AppMemoryHeap.c`). Only `src/static.c`
compiles, and it includes the other sources.

Only `include/`, `src/` and `LICENSE` are kept. The Windows, WASI and
Emscripten folders of `src/prim/` are left out.

To upgrade, copy the same folders from the new tag and update the
version above.
