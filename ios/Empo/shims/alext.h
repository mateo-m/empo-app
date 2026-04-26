/* Shim: redirect <alext.h> to OpenAL-Soft's installed alext.h.
 *
 * Apple's <OpenAL/...> family didn't ship an alext.h, so the
 * previous shim hand-defined `AL_FORMAT_*_FLOAT32`. OpenAL-Soft
 * ships the real thing, complete with all extensions including
 * the float-format constants - just include it.
 */
#include <AL/alext.h>
