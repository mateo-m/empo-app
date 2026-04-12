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
static FILE *s_debugLogFile = nullptr;

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

// Cached safe area insets in logical points, pushed from UIKit.
static std::atomic<float> s_safeAreaTop{0};
static std::atomic<float> s_safeAreaBottom{0};
static std::atomic<float> s_safeAreaLeft{0};
static std::atomic<float> s_safeAreaRight{0};
static std::atomic<bool>  s_safeAreaInsetsChanged{false};

// Input bridge: cached SDL window ID for event injection.
static uint32_t s_sdlWindowID = 0;

// Key event callback: engine -> UI notification for hardware key events.
static mkxp_KeyEventCallback s_keyEventCb = nullptr;
static void *s_keyEventUserdata = nullptr;
static bool s_keyWatcherInstalled = false;

// Lifecycle callbacks: engine -> UI notifications for state changes.
static mkxp_GameReadyCallback s_gameReadyCb = nullptr;
static void *s_gameReadyUserdata = nullptr;

static mkxp_EngineTerminatedCallback s_engineTerminatedCb = nullptr;
static void *s_engineTerminatedUserdata = nullptr;

static mkxp_GameRectChangedCallback s_gameRectChangedCb = nullptr;
static void *s_gameRectChangedUserdata = nullptr;

extern "C" {

void mkxp_setGameReady(void) {
    s_gameReady.store(true, std::memory_order_release);
    if (s_gameReadyCb) {
        s_gameReadyCb(s_gameReadyUserdata);
    }
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
    if (s_engineTerminatedCb) {
        s_engineTerminatedCb(s_engineTerminatedUserdata);
    }
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
    float oldX = s_gameRectX.load(std::memory_order_relaxed);
    float oldY = s_gameRectY.load(std::memory_order_relaxed);
    float oldW = s_gameRectW.load(std::memory_order_relaxed);
    float oldH = s_gameRectH.load(std::memory_order_relaxed);
    s_gameRectX.store(x, std::memory_order_relaxed);
    s_gameRectY.store(y, std::memory_order_relaxed);
    s_gameRectW.store(w, std::memory_order_relaxed);
    s_gameRectH.store(h, std::memory_order_relaxed);
    if (s_gameRectChangedCb && (x != oldX || y != oldY || w != oldW || h != oldH)) {
        s_gameRectChangedCb(x, y, w, h, s_gameRectChangedUserdata);
    }
}

void mkxp_getGameRect(float *x, float *y, float *w, float *h) {
    if (x) *x = s_gameRectX.load(std::memory_order_relaxed);
    if (y) *y = s_gameRectY.load(std::memory_order_relaxed);
    if (w) *w = s_gameRectW.load(std::memory_order_relaxed);
    if (h) *h = s_gameRectH.load(std::memory_order_relaxed);
}

void mkxp_getSafeAreaInsets(float *top, float *bottom, float *left, float *right) {
    if (top)    *top    = s_safeAreaTop.load(std::memory_order_relaxed);
    if (bottom) *bottom = s_safeAreaBottom.load(std::memory_order_relaxed);
    if (left)   *left   = s_safeAreaLeft.load(std::memory_order_relaxed);
    if (right)  *right  = s_safeAreaRight.load(std::memory_order_relaxed);
}

void mkxp_setSafeAreaInsets(float top, float bottom, float left, float right) {
    float oldTop    = s_safeAreaTop.load(std::memory_order_relaxed);
    float oldBottom = s_safeAreaBottom.load(std::memory_order_relaxed);
    float oldLeft   = s_safeAreaLeft.load(std::memory_order_relaxed);
    float oldRight  = s_safeAreaRight.load(std::memory_order_relaxed);
    s_safeAreaTop.store(top, std::memory_order_relaxed);
    s_safeAreaBottom.store(bottom, std::memory_order_relaxed);
    s_safeAreaLeft.store(left, std::memory_order_relaxed);
    s_safeAreaRight.store(right, std::memory_order_relaxed);
    if (top != oldTop || bottom != oldBottom || left != oldLeft || right != oldRight) {
        s_safeAreaInsetsChanged.store(true, std::memory_order_release);
    }
}

bool mkxp_consumeSafeAreaInsetsChanged(void) {
    return s_safeAreaInsetsChanged.exchange(false, std::memory_order_acquire);
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

// ============================================================================
// Lifecycle callbacks
// ============================================================================

void mkxp_setGameReadyCallback(mkxp_GameReadyCallback cb, void *userdata) {
    s_gameReadyCb = cb;
    s_gameReadyUserdata = userdata;
}

void mkxp_setEngineTerminatedCallback(mkxp_EngineTerminatedCallback cb, void *userdata) {
    s_engineTerminatedCb = cb;
    s_engineTerminatedUserdata = userdata;
}

void mkxp_setGameRectChangedCallback(mkxp_GameRectChangedCallback cb, void *userdata) {
    s_gameRectChangedCb = cb;
    s_gameRectChangedUserdata = userdata;
}

void mkxp_setDebugLogPath(const char *path) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    // Close previous file handle if open
    if (s_debugLogFile) {
        fclose(s_debugLogFile);
        s_debugLogFile = nullptr;
    }
    s_debugLogPath = (path && path[0]) ? path : "";
    // Open new file handle for the session
    if (!s_debugLogPath.empty()) {
        s_debugLogFile = fopen(s_debugLogPath.c_str(), "a");
    }
}

void mkxp_debugLog(const char *tag, const char *source, const char *message) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    if (!s_debugLogFile) return;
    fprintf(s_debugLogFile, "[%s] (%s) %s\n", tag, source, message);
    fflush(s_debugLogFile);
}

} // extern "C"

// Internal helper — called by binding-mri.cpp, not part of the C bridge.
// Returns empty string if logging is disabled.
std::string mkxp_getDebugLogPath(void) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    return s_debugLogPath;
}
