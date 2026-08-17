/* extinit.c (Ruby 1.9): hand-rolled replacement for the build-system
 * generated file at ext/extinit.c. Lists the extensions we ship
 * statically in mkxp19-merged.o (matching $RUBY19_EXTS in
 * common.make) and provides Init_ext() so they auto-initialize at
 * Ruby startup.
 *
 * The matching static stub `dmyext.c` (Ruby's source tree) is empty.
 * The build deletes that .o from libruby19-static.a so the real
 * Init_ext below wins at link time.
 *
 * iOS doesn't allow dlopen of arbitrary libraries, so we can't ship
 * extensions as `.so` files for `require` to load. Instead we link
 * them into the merged.o and call their Init_X() at startup. The
 * `ruby_init_ext(name, init)` helper from load.c calls init() and
 * marks the feature as already-loaded so subsequent `require 'name'`
 * returns false (instead of failing with LoadError).
 *
 * Differences from the 1.8 list:
 *   - `thread` is no longer a separate ext in 1.9 (folded into core)
 *   - `pathname` is included since Pokemon Essentials uses it
 *
 * Keep this list in sync with $RUBY19_EXTS in common.make, plus the
 * special-cased socket ext ($SOCKET19_SRCS / $SOCKET19_DEFS there -
 * it needs generated constdefs.c and pinned Darwin extconf results,
 * so it doesn't ride the simple per-ext loop).
 */

#include <stdbool.h>

void ruby_init_ext(const char *name, void (*init)(void));

/* Host bridge (mkxp-z-apple-mobile/src/app_bridge.h), resolved at app
 * link time. */
bool mkxp_getNetworkEnabled(void);

void Init_zlib(void);
void Init_stringio(void);
void Init_strscan(void);
void Init_digest(void);
void Init_fcntl(void);
void Init_pathname(void);
void Init_socket(void);

void Init_ext(void)
{
    ruby_init_ext("zlib.so", Init_zlib);
    ruby_init_ext("stringio.so", Init_stringio);
    ruby_init_ext("strscan.so", Init_strscan);
    ruby_init_ext("digest.so", Init_digest);
    ruby_init_ext("fcntl.so", Init_fcntl);
    ruby_init_ext("pathname.so", Init_pathname);

    /* Only define the real socket classes when the host allows this
     * game onto the network. Some Pokemon Essentials forks ship their
     * own TCPSocket/UDPSocket class hierarchies. With the toggle off
     * the VM must look exactly like the pre-networking builds (no
     * socket constants at all) so those scripts keep loading without
     * superclass mismatches. */
    if (mkxp_getNetworkEnabled())
        ruby_init_ext("socket.so", Init_socket);
}
