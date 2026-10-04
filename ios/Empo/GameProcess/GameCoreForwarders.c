#include "EmpoCore.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

#include "GameCore.h"

static void *gCore;

int EmpoCoreOpen(const char *binaryPath) {
    // RTLD_LOCAL keeps the core's names out of the global namespace.
    // Every name below reaches this image through its own handle.
    gCore = dlopen(binaryPath, RTLD_NOW | RTLD_LOCAL);
    if (gCore == NULL) {
        fprintf(stderr, "EmpoCore: cannot open %s: %s\n", binaryPath, dlerror());
        return 0;
    }
    return 1;
}

// dlsym with the core's handle searches that image only, so the core
// answers under the same name without a clash with the forwarder below.
static void *coreSymbol(const char *symbol) {
    void *address = gCore != NULL ? dlsym(gCore, symbol) : NULL;
    if (address == NULL) {
        // Either the process called the core before it opened one, or
        // the framework and this file were built from different
        // headers. Both are build errors, and a silent no-op would hide
        // them until a game misbehaved.
        fprintf(stderr, "EmpoCore: %s is not available (core open: %d)\n", symbol, gCore != NULL);
        abort();
    }
    return address;
}

#define CORE_FUNCTION(ret, name, params)                                                                     \
    static ret(*fn) params;                                                                                  \
    if (fn == NULL)                                                                                          \
        fn = coreSymbol("gamecore_" #name);

#define GAMECORE_FUNCTION(ret, name, params, args)                                                           \
    ret gamecore_##name params {                                                                             \
        CORE_FUNCTION(ret, name, params)                                                                     \
        return fn args;                                                                                      \
    }

#define GAMECORE_VOID(name, params, args)                                                                    \
    void gamecore_##name params {                                                                            \
        CORE_FUNCTION(void, name, params)                                                                    \
        fn args;                                                                                             \
    }

#include "GameCoreFunctions.h"
