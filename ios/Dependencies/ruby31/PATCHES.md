# Ruby 3.1.3 — Patches & Build Notes

## Source

- **Upstream**: Ruby 3.1.3
- **Fork**: <https://github.com/mkxp-z/ruby> branch `mkxp-z-3.1.3` (submodule at `sources/ruby`)
- **Base commit**: `4d85560` (Nobuyoshi Nakada — "Fix redefinition of `clock_gettime` and `clock_getres`")

## Patches

All iOS patches are in `ios.patch` (applied automatically by the makefile
via `git apply` before `autoreconf`):

### 1. `configure.ac` — Remove DYLD_INSERT_LIBRARIES

The line `: ${PRELOADENV=DYLD_INSERT_LIBRARIES}` is deleted. On iOS,
`DYLD_INSERT_LIBRARIES` is not supported, and referencing it causes
configure warnings/failures.

### 2. `dir.c` — sys/vnode.h iOS shim

`<sys/vnode.h>` is not available in the iOS SDK. When `TARGET_OS_IPHONE`
is true, the header include is skipped and the required constants are
hardcoded:

```c
#define VREG   1
#define VDIR   2
#define VLNK   5
#define VT_HFS  17
#define VT_CIFS 23
```

On macOS, the original `#include <sys/vnode.h>` is used as before.

### 3. `process.c` — system() disabled on iOS

The `system()` C library call is not available on iOS (sandboxing
restrictions). In `rb_spawn_process()`, the call is stubbed out:

```c
#if TARGET_OS_IPHONE
    status = -1; // system() is unavailable on iOS
#else
    status = system(rb_execarg_commandline(...));
#endif
```

## iOS Build Instructions

Built with Autotools:

```
autoreconf -fi
./configure \
  --disable-shared \
  --enable-install-static-library \
  --with-static-linked-ext \
  --with-out-ext=fiddle,gdbm,win32ole,win32,pty,syslog,readline,bigdecimal \
  --disable-rubygems \
  --disable-install-doc \
  --disable-jit-support \
  --build=aarch64-apple-darwin \
  --host=aarch64-apple-darwin \
  <common CONFIGURE_ARGS from common.make>
```

Additional CFLAGS: `-std=gnu99 -DRUBY_FUNCTION_NAME_STRING=__func__`

### Cross-compilation cache overrides

Several functions unavailable or problematic on iOS are forced to `no`
via autoconf cache variables:

```
ac_cv_func_setpgrp_void=yes
ac_cv_func_fork=no
ac_cv_func_dup3=no
ac_cv_func_pipe2=no
ac_cv_func_getentropy=no
ac_cv_func_posix_spawn=no
ac_cv_func_posix_spawnp=no
ac_cv_func_fdatasync=no
ac_cv_func_preadv=no
ac_cv_func_pwritev=no
ac_cv_func_copy_file_range=no
ac_cv_func_close_range=no
cross_compiling=yes
```

### Output

- `libruby.3.1-static.a` — manually copied into `$(LIBDIR)`
- Headers installed to `$(INCLUDEDIR)/ruby-3.1.0/`
