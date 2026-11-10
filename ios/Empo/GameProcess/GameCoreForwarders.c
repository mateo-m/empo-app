// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#include "EmpoCore.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

#include "GameCore.h"

#define GAMECORE_FUNCTION(ret, name, params, args) static ret(*core_##name) params;
#define GAMECORE_VOID(name, params, args) static void(*core_##name) params;
#include "GameCoreFunctions.h"
#undef GAMECORE_FUNCTION
#undef GAMECORE_VOID

const char *EmpoCoreOpen(const char *binaryPath) {
    static char error[1024];
    // RTLD_LOCAL keeps the core's names out of the global namespace.
    // dlsym with the core's handle searches that image only, so the
    // core answers under the same name as the forwarders below.
    void *core = dlopen(binaryPath, RTLD_NOW | RTLD_LOCAL);
    if (core == NULL) {
        snprintf(error, sizeof(error), "cannot open %s: %s", binaryPath, dlerror());
        return error;
    }
#define GAMECORE_VOID(name, params, args)                                                                    \
    core_##name = dlsym(core, "gamecore_" #name);                                                            \
    if (core_##name == NULL) {                                                                               \
        snprintf(error, sizeof(error), "%s has no gamecore_%s", binaryPath, #name);                          \
        return error;                                                                                        \
    }
#define GAMECORE_FUNCTION(ret, name, params, args) GAMECORE_VOID(name, params, args)
#include "GameCoreFunctions.h"
#undef GAMECORE_FUNCTION
#undef GAMECORE_VOID
    return NULL;
}

static void notOpen(const char *name) {
    fprintf(stderr, "EmpoCore: gamecore_%s was called before a core opened\n", name);
    abort();
}

#define GAMECORE_FUNCTION(ret, name, params, args)                                                           \
    ret gamecore_##name params {                                                                             \
        if (core_##name == NULL)                                                                             \
            notOpen(#name);                                                                                  \
        return core_##name args;                                                                             \
    }
#define GAMECORE_VOID(name, params, args)                                                                    \
    void gamecore_##name params {                                                                            \
        if (core_##name == NULL)                                                                             \
            notOpen(#name);                                                                                  \
        core_##name args;                                                                                    \
    }
#include "GameCoreFunctions.h"
