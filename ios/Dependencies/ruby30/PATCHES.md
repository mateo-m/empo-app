# Ruby 3.0: Patches & Build Notes

## Source

- **Upstream**: Ruby 3.0.7 (final 3.0 release before EOL)
- **Branch**: `ruby_3_0` (submodule at `sources/ruby30`)
- **Commit**: `724a071` ("Bump up 3.0.7")

## Why Ruby 3.0?

Mirrors the validated set from JoiPlay's RPG Maker plugin (1.8 / 1.9
/ 3.0) and matches mkxp-z upstream's 3.0 pin. Available as a manual
override via the per-game Ruby Version picker for projects whose
runtime is built against Ruby 3.0 specifically. Auto-detection for
Ruby 3.0-pinned frameworks is a work-in-progress and not currently
wired up; new imports route to 3.1 by default.

## Patches

All iOS patches are in `ios.patch` (applied automatically by the
makefile via `git apply` before `autoreconf`). Same surface as the
3.1 patch, since iOS makes the same things unavailable in both:

### 1. `configure.ac`: Remove DYLD_INSERT_LIBRARIES

The line `: ${PRELOADENV=DYLD_INSERT_LIBRARIES}` is deleted. iOS doesn't
support `DYLD_INSERT_LIBRARIES`; referencing it causes configure
warnings/failures.

### 2. `dir.c`: sys/vnode.h iOS shim

`<sys/vnode.h>` isn't part of the iOS SDK. Under `TARGET_OS_IPHONE`, the
include is skipped and the required constants are hardcoded:

```c
#define VREG    1
#define VDIR    2
#define VLNK    5
#define VT_HFS  17
#define VT_CIFS 23
```

macOS still uses the original `#include <sys/vnode.h>`.

### 3. `process.c`: `system()` disabled on iOS

iOS sandboxing disallows `system()`. In `rb_spawn_process()`, the call
is stubbed:

```c
#if TARGET_OS_IPHONE
    status = -1; // system() unavailable on iOS
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

- `libruby.3.0-static.a`: copied into `$(LIBDIR)`
- Headers installed to `$(INCLUDEDIR)/ruby-3.0.0/`
