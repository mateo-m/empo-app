#ifndef JSON5_BRIDGE_H
#define JSON5_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The result of one normalization call. Exactly one of `json` and
 * `error_message` is non-NULL. Pass each non-NULL pointer to
 * json5_bridge_free after use.
 *
 * `error_line` and `error_column` are 1-based. They point at the
 * input byte that made the parser throw. When the input ends too
 * early, they point one column past the last byte.
 */
typedef struct json5_bridge_result {
    char *json;
    char *error_message;
    long error_line;
    long error_column;
} json5_bridge_result;

/*
 * Parse `length` bytes of UTF-8 JSON5 text with json5pp `parse5`.
 * This is the same call the engine uses for mkxp.json and
 * patches.json. On success, the function re-serializes the value as
 * strict JSON. On a syntax error, it returns the message and the
 * 1-based line and column of the error.
 */
json5_bridge_result json5_bridge_normalize(const char *input, size_t length);

/*
 * Free a string that json5_bridge_normalize returned.
 */
void json5_bridge_free(char *text);

#ifdef __cplusplus
}
#endif

#endif /* JSON5_BRIDGE_H */
