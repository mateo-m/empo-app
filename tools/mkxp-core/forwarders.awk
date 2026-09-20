# Read the MKXPZ_MOBILE block of app_bridge.h and print one dlsym
# forwarder for every mkxp_* function it declares.
# tools/mkxp-core/generate-core-forwarders.sh runs this.

/^#if MKXPZ_MOBILE/ {
    inblock = 1
    next
}
/^#else/ {
    inblock = 0
}
!inblock {
    next
}
/^[ \t]*#/ {
    next
}
{
    line = $0

    # Block comments. The header uses them around several
    # declarations, and their text would otherwise become part of the
    # next return type.
    if (incomment) {
        shutpos = index(line, "*/")
        if (shutpos == 0) {
            next
        }
        line = substr(line, shutpos + 2)
        incomment = 0
    }
    while (match(line, /\/\*.*\*\//)) {
        line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
    }
    openpos = index(line, "/*")
    if (openpos > 0) {
        line = substr(line, 1, openpos - 1)
        incomment = 1
    }

    sub(/\/\/.*$/, "", line)
    if (line ~ /^[ \t]*$/) {
        next
    }
    buf = buf " " line
    if (index(buf, ";") == 0) {
        next
    }
    sub(/;.*$/, "", buf)
    # The block opens with `extern "C" {`, which is not a preprocessor
    # line and would otherwise land in the first return type.
    gsub(/extern "C"/, "", buf)
    gsub(/[{}]/, "", buf)
    gsub(/[ \t]+/, " ", buf)
    sub(/^ /, "", buf)
    sub(/ $/, "", buf)

    open = index(buf, "(")
    shut = index(buf, ")")
    if (open == 0 || shut == 0) {
        buf = ""
        next
    }

    head = substr(buf, 1, open - 1)
    params = substr(buf, open + 1, shut - open - 1)

    # The name is the last identifier of the head, and the return type
    # is everything before it. "const char *mkxp_getX" has no space
    # between the star and the name, so cut on the identifier.
    if (match(head, /[A-Za-z_][A-Za-z0-9_]*[ \t]*$/) == 0) {
        buf = ""
        next
    }
    name = substr(head, RSTART, RLENGTH)
    gsub(/[ \t]/, "", name)
    ret = substr(head, 1, RSTART - 1)
    sub(/ $/, "", ret)
    if (name !~ /^mkxp_/) {
        buf = ""
        next
    }

    # Forward each argument by name, which is the last identifier of
    # the parameter.
    args = ""
    n = split(params, parts, ",")
    i = 1
    while (i <= n) {
        p = parts[i]
        i = i + 1
        gsub(/^[ \t]+|[ \t]+$/, "", p)
        if (p == "void" || p == "") {
            continue
        }
        if (match(p, /[A-Za-z_][A-Za-z0-9_]*$/) == 0) {
            continue
        }
        arg = substr(p, RSTART, RLENGTH)
        args = (args == "") ? arg : args ", " arg
    }

    printf "%s %s(%s) {\n", ret, name, params
    printf "    static %s (*fn)(%s);\n", ret, params
    printf "    if (fn == NULL) {\n"
    printf "        fn = coreSymbol(\"%s\");\n", name
    printf "    }\n"
    if (ret == "void") {
        printf "    fn(%s);\n", args
    } else {
        printf "    return fn(%s);\n", args
    }
    printf "}\n\n"
    buf = ""
}
