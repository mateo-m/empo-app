/* extinit.c (Ruby 1.8): hand-rolled replacement for the build-system
 * generated file at ext/extinit.c. Lists the extensions we ship
 * statically in mkxp18-merged.o (matching $RUBY18_EXTS in
 * common.make) and provides Init_ext() so they auto-initialize at
 * Ruby startup.
 *
 * The matching static stub `dmyext.c` (Ruby's source tree) is empty;
 * the build deletes that .o from libruby18-static.a so the real
 * Init_ext below wins at link time.
 *
 * iOS doesn't allow dlopen of arbitrary libraries, so we can't ship
 * extensions as `.so` files for `require` to load. Instead we link
 * them into the merged.o and call their Init_X() at startup. The
 * `ruby_init_ext(name, init)` helper from eval.c calls init() and
 * marks the feature as already-loaded so subsequent `require 'name'`
 * returns false (instead of failing with LoadError).
 *
 * Keep this list in sync with $RUBY18_EXTS in common.make. Adding an
 * extension requires three changes: (1) add it to RUBY18_EXTS, (2)
 * declare and call its Init_X here, (3) make sure the extension
 * configures cleanly (some need extconf-time tweaks for iOS).
 */

void ruby_init_ext(const char *name, void (*init)(void));

void Init_zlib(void);
void Init_stringio(void);
void Init_strscan(void);
void Init_digest(void);
void Init_fcntl(void);

void Init_ext(void)
{
    ruby_init_ext("zlib.so", Init_zlib);
    ruby_init_ext("stringio.so", Init_stringio);
    ruby_init_ext("strscan.so", Init_strscan);
    ruby_init_ext("digest.so", Init_digest);
    ruby_init_ext("fcntl.so", Init_fcntl);
}
