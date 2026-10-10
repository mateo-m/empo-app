#include "EmpoAppCore.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "GameCore.h"

static bool gUseGameProcess;
static void *gCore;
static char gCorePath[1024];
// Goes up each time a different core opens. A forwarder looks its
// symbol up again when this changed.
static unsigned gCoreGeneration;
static int gSessionKilled;

void EmpoCoreUseGameProcess(bool use) {
    gUseGameProcess = use;
}

int EmpoCoreOpen(const char *binaryPath) {
    if (gCore != NULL && strcmp(gCorePath, binaryPath) == 0) {
        gSessionKilled = 0;
        return 1;
    }
    if (gCore != NULL && !gSessionKilled) {
        // The open core still holds a game, and its threads, globals
        // and working directory would run next to the new engine.
        fprintf(stderr, "EmpoCore: %s holds a game, refusing %s\n", gCorePath, binaryPath);
        return 0;
    }
    // RTLD_LOCAL keeps the core's names out of the global namespace.
    // Every name below reaches this image through its own handle.
    //
    // A killed core stays loaded: dlclose does not unload an image that
    // ran static initializers or registered ObjC classes. It holds no
    // game, and scripts/audit-ipa.sh keeps its class names its own.
    void *core = dlopen(binaryPath, RTLD_NOW | RTLD_LOCAL);
    if (core == NULL) {
        fprintf(stderr, "EmpoCore: cannot open %s: %s\n", binaryPath, dlerror());
        return 0;
    }
    gCore = core;
    gCoreGeneration++;
    gSessionKilled = 0;
    snprintf(gCorePath, sizeof(gCorePath), "%s", binaryPath);
    return 1;
}

void EmpoCoreKillSession(void) {
    gamecore_killSession();
    gSessionKilled = 1;
}

int EmpoCoreIsOpen(void) {
    return gUseGameProcess ? EmpoGameProcessIsOpen() : gCore != NULL;
}

// dlsym with the core's handle searches that image only, so each core
// answers under the same name without a clash with the forwarder below
// or with another core that stays loaded after a kill.
static void *coreSymbol(const char *symbol) {
    void *address = gCore != NULL ? dlsym(gCore, symbol) : NULL;
    if (address == NULL) {
        // Either the app called the core before it picked a game, or
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
    static unsigned generation;                                                                              \
    if (fn == NULL || generation != gCoreGeneration) {                                                       \
        fn = coreSymbol("gamecore_" #name);                                                                  \
        generation = gCoreGeneration;                                                                        \
    }

// GameProcessClient.m defines a gameprocess_* function for each one.
#define GAMECORE_FUNCTION(ret, name, params, args)                                                           \
    ret gameprocess_##name params;                                                                           \
    ret gamecore_##name params {                                                                             \
        if (gUseGameProcess)                                                                                 \
            return gameprocess_##name args;                                                                  \
        CORE_FUNCTION(ret, name, params)                                                                     \
        return fn args;                                                                                      \
    }

#define GAMECORE_VOID(name, params, args)                                                                    \
    void gameprocess_##name params;                                                                          \
    void gamecore_##name params {                                                                            \
        if (gUseGameProcess) {                                                                               \
            gameprocess_##name args;                                                                         \
            return;                                                                                          \
        }                                                                                                    \
        CORE_FUNCTION(void, name, params)                                                                    \
        fn args;                                                                                             \
    }

#include "GameCoreFunctions.h"
