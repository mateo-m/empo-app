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

// Debug log path for Ruby errors (empty = disabled).
static std::mutex s_debugLogMutex;
static std::string s_debugLogPath;

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

// Input bridge: cached SDL window ID for event injection.
static uint32_t s_sdlWindowID = 0;

// Key event callback: engine -> UI notification for hardware key events.
static mkxp_KeyEventCallback s_keyEventCb = nullptr;
static void *s_keyEventUserdata = nullptr;
static bool s_keyWatcherInstalled = false;

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
    s_sdlWindowID = 0;
    {
        std::lock_guard<std::mutex> lock(s_pathMutex);
        s_gamePath.clear();
    }
}

double mkxp_getAverageFPS(void) {
    if (s_engineTerminated.load(std::memory_order_acquire)) return 0.0;
    if (!SharedState::instance) return 0.0;
    return SharedState::instance->graphics().averageFrameRate();
}

int mkxp_getRGSSVersion(void) {
    if (s_engineTerminated.load(std::memory_order_acquire)) return 0;
    if (!SharedState::instance) return 0;
    return SharedState::instance->rtData().config.rgssVersion;
}

const char *mkxp_getGameTitle(void) {
    if (s_engineTerminated.load(std::memory_order_acquire)) return "";
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

// ============================================================================
// Input bridge
// ============================================================================

void mkxp_injectKeyEvent(int scancode, int pressed) {
    // Lazily resolve the SDL window ID on first use
    if (s_sdlWindowID == 0) {
        SDL_Window *w = SDL_GetGrabbedWindow();
        if (w) {
            s_sdlWindowID = SDL_GetWindowID(w);
        } else {
            // Single-window app: SDL window IDs start at 1
            s_sdlWindowID = 1;
        }
    }

    SDL_Event event;
    memset(&event, 0, sizeof(event));
    event.type              = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.timestamp     = SDL_GetTicks();
    event.key.windowID      = s_sdlWindowID;
    event.key.state         = pressed ? SDL_PRESSED : SDL_RELEASED;
    event.key.repeat        = 0;
    event.key.keysym.scancode = (SDL_Scancode)scancode;
    event.key.keysym.sym    = SDL_GetKeyFromScancode((SDL_Scancode)scancode);
    event.key.keysym.mod    = KMOD_NONE;
    SDL_PushEvent(&event);
}

static int keyEventWatcherFn(void * /*userdata*/, SDL_Event *event) {
    if (event->type == SDL_KEYDOWN || event->type == SDL_KEYUP) {
        int pressed = (event->type == SDL_KEYDOWN) ? 1 : 0;
        int sc = (int)event->key.keysym.scancode;
        if (s_keyEventCb) {
            s_keyEventCb(sc, pressed, s_keyEventUserdata);
        }
    }
    return 1; // keep processing the event
}

void mkxp_setKeyEventCallback(mkxp_KeyEventCallback cb, void *userdata) {
    s_keyEventCb = cb;
    s_keyEventUserdata = userdata;
    if (!s_keyWatcherInstalled) {
        SDL_AddEventWatch(keyEventWatcherFn, NULL);
        s_keyWatcherInstalled = true;
    }
}

void mkxp_setDebugLogPath(const char *path) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    s_debugLogPath = (path && path[0]) ? path : "";
}

void mkxp_debugLog(const char *tag, const char *source, const char *message) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    if (s_debugLogPath.empty()) return;
    FILE *f = fopen(s_debugLogPath.c_str(), "a");
    if (f) {
        fprintf(f, "[%s] (%s) %s\n", tag, source, message);
        fclose(f);
    }
}

} // extern "C"

// Internal helper — called by binding-mri.cpp, not part of the C bridge.
// Returns empty string if logging is disabled.
std::string mkxp_getDebugLogPath(void) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    return s_debugLogPath;
}
