/* Shim: redirect <al.h> to OpenAL-Soft's installed header layout.
 *
 * Engine sources include <al.h>, OpenAL-Soft installs into
 * <AL/al.h>. Mapping happens here so we don't have to patch
 * every engine include site.
 */
#include <AL/al.h>
