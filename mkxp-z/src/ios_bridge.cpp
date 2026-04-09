// ios_bridge.cpp — Minimal C bridge for iOS overlay to query engine state.
// Kept separate from engine code. No UIKit imports. No game logic.

#include "ios_bridge.h"
#include "sharedstate.h"
#include "graphics.h"
#include "eventthread.h"
#include "config.h"
#include <atomic>
#include <mutex>
#include <string>

#include <SDL.h>

#if TARGET_OS_IPHONE
#include <CoreFoundation/CoreFoundation.h>
#endif

static std::atomic<bool> s_gameReady{false};

// Game path selection: Library sets the path, engine waits for it.
static std::mutex s_pathMutex;
static std::string s_gamePath;
static std::atomic<bool> s_pathSet{false};

// Engine terminated flag: set by engine after full teardown.
static std::atomic<bool> s_engineTerminated{false};

// Game viewport rect in logical points, updated by the engine each frame.
static std::atomic<float> s_gameRectX{0};
static std::atomic<float> s_gameRectY{0};
static std::atomic<float> s_gameRectW{0};
static std::atomic<float> s_gameRectH{0};

extern "C" {

void mkxp_setGameReady(void) {
    s_gameReady.store(true, std::memory_order_release);
}

int mkxp_isGameReady(void) {
    return s_gameReady.load(std::memory_order_acquire) ? 1 : 0;
}

void mkxp_setGamePath(const char *path) {
    std::lock_guard<std::mutex> lock(s_pathMutex);
    s_gamePath = path ? path : "";
    s_pathSet.store(true, std::memory_order_release);
}

const char *mkxp_waitForGamePath(void) {
#if TARGET_OS_IPHONE
    // On iOS, SDL_main runs on the main thread. We must pump the main
    // run loop while waiting so that UIKit can render the Library UI
    // and dispatch_async blocks can execute.
    while (!s_pathSet.load(std::memory_order_acquire)) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
#else
    while (!s_pathSet.load(std::memory_order_acquire)) {
        // spin (non-iOS fallback, shouldn't be reached)
    }
#endif
    std::lock_guard<std::mutex> lock(s_pathMutex);
    return s_gamePath.c_str();
}

void mkxp_requestTerminate(void) {
    // Push SDL_QUIT into the event queue. The engine's event loop
    // will pick it up and initiate normal shutdown.
    SDL_Event event;
    event.type = SDL_QUIT;
    SDL_PushEvent(&event);
}

int mkxp_isEngineTerminated(void) {
    return s_engineTerminated.load(std::memory_order_acquire) ? 1 : 0;
}

void mkxp_setEngineTerminated(void) {
    s_engineTerminated.store(true, std::memory_order_release);
    // Clear pathSet so the next mkxp_waitForGamePath() actually blocks
    // until the Library UI provides a new game selection.
    s_pathSet.store(false, std::memory_order_release);
}

void mkxp_resetBridgeState(void) {
    s_gameReady.store(false, std::memory_order_release);
    s_pathSet.store(false, std::memory_order_release);
    s_engineTerminated.store(false, std::memory_order_release);
    s_gameRectX.store(0, std::memory_order_relaxed);
    s_gameRectY.store(0, std::memory_order_relaxed);
    s_gameRectW.store(0, std::memory_order_relaxed);
    s_gameRectH.store(0, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(s_pathMutex);
        s_gamePath.clear();
    }
}

double mkxp_getAverageFPS(void) {
    if (!SharedState::instance) return 0.0;
    return SharedState::instance->graphics().averageFrameRate();
}

int mkxp_getRGSSVersion(void) {
    if (!SharedState::instance) return 0;
    return SharedState::instance->rtData().config.rgssVersion;
}

const char *mkxp_getGameTitle(void) {
    if (!SharedState::instance) return "";
    return SharedState::instance->rtData().config.game.title.c_str();
}

void mkxp_setGameRect(float x, float y, float w, float h) {
    s_gameRectX.store(x, std::memory_order_relaxed);
    s_gameRectY.store(y, std::memory_order_relaxed);
    s_gameRectW.store(w, std::memory_order_relaxed);
    s_gameRectH.store(h, std::memory_order_relaxed);
}

void mkxp_getGameRect(float *x, float *y, float *w, float *h) {
    if (x) *x = s_gameRectX.load(std::memory_order_relaxed);
    if (y) *y = s_gameRectY.load(std::memory_order_relaxed);
    if (w) *w = s_gameRectW.load(std::memory_order_relaxed);
    if (h) *h = s_gameRectH.load(std::memory_order_relaxed);
}

} // extern "C"
