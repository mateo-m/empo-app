# Ruby 3.1: patches and build notes

## Source

- **Upstream**: Ruby 3.1.3
- **Fork**: <https://github.com/mkxp-z/ruby> branch `mkxp-z-3.1.3`
  (submodule at `sources/ruby`)
- **Base commit**: `4d85560` (Nobuyoshi Nakada: "Fix redefinition of
  `clock_gettime` and `clock_getres`")

## Why Ruby 3.1?

Modern Pokemon Essentials forks on the mkxp-z runtime target Ruby 3.x.
Ruby 3.1 is also the only Empo build with the syntax-transform patches
enabled (see `docs/multi-ruby.md`, "Syntax transform stays").
Mixed-grammar Pokemon Essentials forks, which combine 1.8-era syntax
with 1.9+ runtime methods, route here in LEGACY transform mode.

## Patches

All iOS patches are in `ios.patch`. The makefile applies it
automatically via `git apply` before `autoreconf`:

### 1. `configure.ac`: remove DYLD_INSERT_LIBRARIES

The patch deletes the line `: ${PRELOADENV=DYLD_INSERT_LIBRARIES}`.
iOS does not support `DYLD_INSERT_LIBRARIES`, and a reference to it
causes configure warnings or failures.

### 2. `dir.c`: sys/vnode.h iOS shim

The iOS SDK does not include `<sys/vnode.h>`. When `TARGET_OS_IPHONE`
is true, the patch skips the header include and hardcodes the required
constants:

```c
#define VREG   1
#define VDIR   2
#define VLNK   5
#define VT_HFS  17
#define VT_CIFS 23
```

On macOS, the code uses the original `#include <sys/vnode.h>` as before.

### 3. `process.c`: system() disabled on iOS

iOS does not provide the `system()` C library call (sandbox
restrictions). The patch stubs out the call in `rb_spawn_process()`:

```c
#if TARGET_OS_IPHONE
    status = -1; // system() is unavailable on iOS
#else
    status = system(rb_execarg_commandline(...));
#endif
```

## iOS build instructions

The build uses Autotools:

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

Autoconf cache variables force several functions to `no`. These
functions are unavailable or problematic on iOS:

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

- `libruby.3.1-static.a`: copied manually into `$(LIBDIR)`
- Headers go to `$(INCLUDEDIR)/ruby-3.1.0/`
