/* The one header the CSQLite module exposes.
 *
 * Apple platforms ship sqlite3.h in the SDK. Linux gets it from the
 * libsqlite3-dev package, which the module map names as its apt
 * provider. One module map for both keeps the state store of SPEC 6.2
 * in the GameProbe package, where `swift test` reaches it on macOS and
 * on Linux.
 */
#include <sqlite3.h>
