// C shim over the engine's json5pp parser. The shim parses JSON5
// input with the same `parse5` entry point the engine uses. It then
// re-serializes the parsed value as strict JSON.
//
// The shim does not use json5pp's own stringifier for output. That
// stringifier prints doubles with the default ostream precision of
// six significant digits, which loses precision. The writer below
// keeps json5pp's integer/double split and prints doubles with the
// shortest text that round-trips.

#include "include/json5_bridge.h"
#include "json5pp.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>

namespace {

char *copy_string(const std::string &text)
{
    char *buffer = static_cast<char *>(std::malloc(text.size() + 1));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, text.data(), text.size());
    buffer[text.size()] = '\0';
    return buffer;
}

// Write one double as a strict JSON number.
//
// json5pp yields NaN for `NaN` and an IEEE infinity for `infinity`.
// Strict JSON has no literal for either value. The writer emits
// `null` for NaN and the greatest finite double for infinity. This
// matches the stand-ins the launcher has always used.
//
// For finite values, the writer probes 15, 16, and 17 significant
// digits and keeps the first text that parses back to the same
// double. Seventeen digits always round-trip.
void write_double(double number, std::string &out)
{
    if (std::isnan(number)) {
        out += "null";
        return;
    }
    if (std::isinf(number)) {
        out += (number > 0) ? "1.7976931348623157e308"
                            : "-1.7976931348623157e308";
        return;
    }
    char buffer[32];
    for (int precision = 15; precision <= 17; ++precision) {
        std::snprintf(buffer, sizeof(buffer), "%.*g", precision, number);
        if (std::strtod(buffer, nullptr) == number) {
            break;
        }
    }
    out += buffer;
}

// Write one string with the same escapes json5pp's stringifier
// uses. UTF-8 bytes above the control range pass through raw.
void write_string(const std::string &text, std::string &out)
{
    static const char hex[] = "0123456789abcdef";
    out += '"';
    for (const char c : text) {
        const unsigned char ch = static_cast<unsigned char>(c);
        switch (ch) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b";  break;
        case '\f': out += "\\f";  break;
        case '\n': out += "\\n";  break;
        case '\r': out += "\\r";  break;
        case '\t': out += "\\t";  break;
        default:
            if (ch < ' ') {
                out += "\\u00";
                out += hex[(ch >> 4) & 0xf];
                out += hex[ch & 0xf];
            } else {
                out += static_cast<char>(ch);
            }
            break;
        }
    }
    out += '"';
}

void write_value(const json5pp::value &value, std::string &out)
{
    if (value.is_null()) {
        out += "null";
        return;
    }
    if (value.is_boolean()) {
        out += value.as_boolean() ? "true" : "false";
        return;
    }
    // Check the integer case before the general number case.
    // `is_number` is also true for integers.
    if (value.is_integer()) {
        char buffer[16];
        std::snprintf(buffer, sizeof(buffer), "%d", value.as_integer());
        out += buffer;
        return;
    }
    if (value.is_number()) {
        write_double(value.as_number(), out);
        return;
    }
    if (value.is_string()) {
        write_string(value.as_string(), out);
        return;
    }
    if (value.is_array()) {
        out += '[';
        const char *delimiter = "";
        for (const auto &element : value.as_array()) {
            out += delimiter;
            write_value(element, out);
            delimiter = ",";
        }
        out += ']';
        return;
    }
    // The last case is an object. json5pp stores object members in
    // a std::map, so the output carries the keys in sorted order.
    out += '{';
    const char *delimiter = "";
    for (const auto &member : value.as_object()) {
        out += delimiter;
        write_string(member.first, out);
        out += ':';
        write_value(member.second, out);
        delimiter = ",";
    }
    out += '}';
}

// Convert a byte offset into a 1-based line and column pair.
void locate_offset(const std::string &text, size_t offset,
                   long *line, long *column)
{
    long current_line = 1;
    // The index of the newline before `offset`, or -1 when `offset`
    // sits on the first line.
    long long last_newline = -1;
    const size_t limit = (offset < text.size()) ? offset : text.size();
    for (size_t i = 0; i < limit; ++i) {
        if (text[i] == '\n') {
            ++current_line;
            last_newline = static_cast<long long>(i);
        }
    }
    *line = current_line;
    *column = static_cast<long>(static_cast<long long>(limit) - last_newline);
}

} /* namespace */

extern "C" json5_bridge_result json5_bridge_normalize(const char *input,
                                                      size_t length)
{
    json5_bridge_result result = {nullptr, nullptr, 0, 0};

    std::string text;
    if (input != nullptr && length > 0) {
        text.assign(input, length);
    }

    // The shim owns the stream. On a syntax error, the read position
    // tells where the parser stopped.
    std::istringstream stream(text);
    try {
        const json5pp::value parsed = json5pp::parse5(stream, true);
        std::string out;
        write_value(parsed, out);
        result.json = copy_string(out);
        if (result.json == nullptr) {
            result.error_message = copy_string("out of memory");
            result.error_line = 1;
            result.error_column = 1;
        }
        return result;
    } catch (const std::exception &error) {
        // The parser consumed the byte that raised the error, so the
        // read position sits one byte past it. Step back one byte to
        // point at the byte itself. When the input ended too early,
        // keep the end position. It then points one column past the
        // last byte. The stream flags are not a reliable end marker
        // here. json5pp calls unget() on some paths and that clears
        // eofbit. The exception text is reliable. json5pp writes
        // "unexpected EOS" exactly when it reads past the end.
        const bool ended_early =
            std::strstr(error.what(), "unexpected EOS") != nullptr;
        stream.clear();
        long long offset = static_cast<long long>(stream.tellg());
        if (offset < 0 || offset > static_cast<long long>(text.size())) {
            offset = static_cast<long long>(text.size());
        }
        if (!ended_early && offset > 0) {
            --offset;
        }
        long line = 1;
        long column = 1;
        locate_offset(text, static_cast<size_t>(offset), &line, &column);
        result.error_message = copy_string(error.what());
        result.error_line = line;
        result.error_column = column;
        return result;
    }
}

extern "C" void json5_bridge_free(char *text)
{
    std::free(text);
}
