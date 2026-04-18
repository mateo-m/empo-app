// ios_bridge.cpp — Minimal C bridge for iOS overlay to query engine state.
// Kept separate from engine code. No UIKit imports. No game logic.

#include "ios_bridge.h"
#include "sharedstate.h"
#include "graphics.h"
#include "audio.h"
#include "eventthread.h"
#include "config.h"
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <string>
#include <vector>

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
static std::atomic<bool> s_terminateRequested{false};
// Set when the RGSS thread failed to ack a termination request in time.
// The UI reads this via mkxp_isEngineHung() and force-quits the app
// because the single-reused-thread architecture cannot recover.
static std::atomic<bool> s_engineHung{false};
static std::atomic<bool> s_glContextBroken{false};

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

// Per-game settings: vertical alignment and postload toggle.
static std::atomic<int>   s_verticalAlignment{1};  // 0=top, 1=top-center, 2=center
static std::atomic<bool>  s_postloadEnabled{true};

// Debug: tint the area outside the game viewport.
static std::atomic<bool>  s_showViewportBounds{false};
static std::atomic<float> s_vpBoundsR{0};
static std::atomic<float> s_vpBoundsG{0};
static std::atomic<float> s_vpBoundsB{0};
static std::atomic<float> s_vpBoundsA{1};

// Input bridge: cached SDL window ID for event injection.
static std::atomic<uint32_t> s_sdlWindowID{0};

// Key event callback: engine -> UI notification for hardware key events.
// Userdata is always written before the callback pointer (release) so
// the reader (acquire on the pointer) sees both consistently.
static std::atomic<mkxp_KeyEventCallback> s_keyEventCb{nullptr};
static void *s_keyEventUserdata = nullptr;
static bool s_keyWatcherInstalled = false;

// Lifecycle callbacks: engine -> UI notifications for state changes.
// Same write-userdata-then-pointer contract as above.
static std::atomic<mkxp_EngineTerminatedCallback> s_engineTerminatedCb{nullptr};
static void *s_engineTerminatedUserdata = nullptr;

static std::atomic<mkxp_GameRectChangedCallback> s_gameRectChangedCb{nullptr};
static void *s_gameRectChangedUserdata = nullptr;

// Error message routing: engine -> UI.
static std::mutex s_errorMsgMutex;
static std::string s_errorMessage;
static std::atomic<mkxp_ErrorMessageCallback> s_errorMsgCb{nullptr};
static void *s_errorMsgUserdata = nullptr;

// Pause / Resume state.
static std::atomic<bool> s_pauseRequested{false};
static std::atomic<bool> s_paused{false};
static std::mutex s_pauseMutex;
static std::condition_variable s_pauseCV;

// Snapshot buffer: owned by the bridge, written by engine, read by UI.
static std::mutex s_snapshotMutex;
static std::vector<unsigned char> s_snapshotData;
static int s_snapshotWidth = 0;
static int s_snapshotHeight = 0;

// Pause/resume callbacks.
static std::atomic<mkxp_PausedCallback> s_pausedCb{nullptr};
static void *s_pausedUserdata = nullptr;
static std::atomic<mkxp_ResumedCallback> s_resumedCb{nullptr};
static void *s_resumedUserdata = nullptr;

// Frame-rendered-after-resume: one-shot signal so the UI knows
// the live SDL surface is visible and the snapshot can fade out.
static std::atomic<bool> s_needsFrameRenderedSignal{false};
static std::atomic<mkxp_FrameRenderedCallback> s_frameRenderedCb{nullptr};
static void *s_frameRenderedUserdata = nullptr;

extern "C" {

void mkxp_setGameReady(void) {
    s_gameReady.store(true, std::memory_order_release);
    // Arm the frame-rendered signal so the UI knows when the first
    // frame has actually been swapped to the screen.
    s_needsFrameRenderedSignal.store(true, std::memory_order_release);
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
    // Copy under lock so the returned c_str() remains valid until the
    // next call from this thread (thread_local lifetime).
    thread_local std::string pathCopy;
    std::lock_guard<std::mutex> lock(s_pathMutex);
    pathCopy = s_gamePath;
    return pathCopy.c_str();
}

void mkxp_requestTerminate(void) {
    s_terminateRequested.store(true, std::memory_order_release);

    // If the engine is paused on the condvar, unblock it so it can
    // process SDL_QUIT. This avoids needing a separate resume call.
    {
        std::lock_guard<std::mutex> lock(s_pauseMutex);
        s_paused.store(false, std::memory_order_release);
        s_pauseRequested.store(false, std::memory_order_release);
    }
    s_pauseCV.notify_one();

    // Push SDL_QUIT into the event queue. The engine's event loop
    // will pick it up and initiate normal shutdown.
    SDL_Event event;
    event.type = SDL_QUIT;
    SDL_PushEvent(&event);
}

int mkxp_isEngineTerminated(void) {
    return s_engineTerminated.load(std::memory_order_acquire) ? 1 : 0;
}

int mkxp_isEngineHung(void) {
    return s_engineHung.load(std::memory_order_acquire) ? 1 : 0;
}

void mkxp_setEngineHung(void) {
    s_engineHung.store(true, std::memory_order_release);
}

void mkxp_setEngineTerminated(void) {
    s_engineTerminated.store(true, std::memory_order_release);
    // Clear pathSet so the next mkxp_waitForGamePath() actually blocks
    // until the Library UI provides a new game selection.
    s_pathSet.store(false, std::memory_order_release);
    if (auto cb = s_engineTerminatedCb.load(std::memory_order_acquire)) {
        cb(s_engineTerminatedUserdata);
    }
}

void mkxp_resetBridgeState(void) {
    s_gameReady.store(false, std::memory_order_release);
    s_pathSet.store(false, std::memory_order_release);
    s_engineTerminated.store(false, std::memory_order_release);
    s_terminateRequested.store(false, std::memory_order_release);
    s_gameRectX.store(0, std::memory_order_relaxed);
    s_gameRectY.store(0, std::memory_order_relaxed);
    s_gameRectW.store(0, std::memory_order_relaxed);
    s_gameRectH.store(0, std::memory_order_relaxed);
    // Note: s_verticalAlignment and s_postloadEnabled are NOT reset here.
    // They are explicitly set by selectGame() before each session.
    s_sdlWindowID.store(0, std::memory_order_relaxed);
    // Reset pause state so a stale pause doesn't block the next session.
    s_pauseRequested.store(false, std::memory_order_relaxed);
    s_paused.store(false, std::memory_order_relaxed);
    s_needsFrameRenderedSignal.store(false, std::memory_order_relaxed);
    s_glContextBroken.store(false, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(s_snapshotMutex);
        s_snapshotData.clear();
        s_snapshotWidth = 0;
        s_snapshotHeight = 0;
    }
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
    auto rectCb = s_gameRectChangedCb.load(std::memory_order_acquire);
    if (rectCb && (x != oldX || y != oldY || w != oldW || h != oldH)) {
        rectCb(x, y, w, h, s_gameRectChangedUserdata);
    }
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

// Input bridge

void mkxp_injectKeyEvent(int scancode, int pressed) {
    if (s_sdlWindowID.load(std::memory_order_relaxed) == 0) {
        SDL_Window *w = SDL_GetGrabbedWindow();
        if (w) {
            s_sdlWindowID.store(SDL_GetWindowID(w), std::memory_order_relaxed);
        } else {
            // Single-window app: SDL window IDs start at 1
            s_sdlWindowID.store(1, std::memory_order_relaxed);
        }
    }

    SDL_Event event{};
    event.type              = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.timestamp     = SDL_GetTicks();
    event.key.windowID      = s_sdlWindowID.load(std::memory_order_relaxed);
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
        if (auto cb = s_keyEventCb.load(std::memory_order_acquire)) {
            cb(sc, pressed, s_keyEventUserdata);
        }
    }
    return 1; // keep processing the event
}

void mkxp_setKeyEventCallback(mkxp_KeyEventCallback cb, void *userdata) {
    s_keyEventUserdata = userdata;
    s_keyEventCb.store(cb, std::memory_order_release);
    if (!s_keyWatcherInstalled) {
        SDL_AddEventWatch(keyEventWatcherFn, NULL);
        s_keyWatcherInstalled = true;
    }
}

// Lifecycle callbacks

void mkxp_setEngineTerminatedCallback(mkxp_EngineTerminatedCallback cb, void *userdata) {
    s_engineTerminatedUserdata = userdata;
    s_engineTerminatedCb.store(cb, std::memory_order_release);
}

void mkxp_setGameRectChangedCallback(mkxp_GameRectChangedCallback cb, void *userdata) {
    s_gameRectChangedUserdata = userdata;
    s_gameRectChangedCb.store(cb, std::memory_order_release);
}

// Error message routing

void mkxp_setErrorMessage(const char *message) {
    {
        std::lock_guard<std::mutex> lock(s_errorMsgMutex);
        s_errorMessage = message ? message : "";
    }
    auto errCb = s_errorMsgCb.load(std::memory_order_acquire);
    if (errCb && message && message[0]) {
        errCb(message, s_errorMsgUserdata);
    }
}

void mkxp_setErrorMessageCallback(mkxp_ErrorMessageCallback cb, void *userdata) {
    s_errorMsgUserdata = userdata;
    s_errorMsgCb.store(cb, std::memory_order_release);
}

// Pause / Resume

void mkxp_requestPause(void) {
    s_pauseRequested.store(true, std::memory_order_release);
}

void mkxp_requestResume(void) {
    {
        std::lock_guard<std::mutex> lock(s_pauseMutex);
        s_pauseRequested.store(false, std::memory_order_release);
        s_paused.store(false, std::memory_order_release);
    }
    // Arm the one-shot frame-rendered signal so the UI knows when the
    // first post-resume frame has been swapped to the screen.
    s_needsFrameRenderedSignal.store(true, std::memory_order_release);
    s_pauseCV.notify_one();
}

void mkxp_checkPause(void) {
    if (!s_pauseRequested.load(std::memory_order_acquire) &&
        !s_paused.load(std::memory_order_acquire))
        return;

    /* Pause every AL_PLAYING source.  We intentionally do NOT
     * detach the OpenAL context — keeping it current avoids
     * any audio blip that Apple's implementation produces when
     * a context is restored via alcMakeContextCurrent(). */
    if (SharedState::instance)
        SharedState::instance->audio().pauseSources();

    s_paused.store(true, std::memory_order_release);

    if (auto cb = s_pausedCb.load(std::memory_order_acquire))
        cb(s_pausedUserdata);

    /* Block until resume is requested. */
    std::unique_lock<std::mutex> lock(s_pauseMutex);
    s_pauseCV.wait(lock, [] {
        return !s_paused.load(std::memory_order_acquire);
    });

    if (!s_terminateRequested.load(std::memory_order_acquire)) {
        /* Normal resume — un-pause the sources we paused. */
        if (SharedState::instance)
            SharedState::instance->audio().resumeSources();
    }
    /* On terminate the sources stay paused (silent) until
     * SharedState::finiInstance() deletes them. */

    if (auto cb = s_resumedCb.load(std::memory_order_acquire))
        cb(s_resumedUserdata);
}

bool mkxp_isPauseRequested(void) {
    return s_pauseRequested.load(std::memory_order_acquire);
}

bool mkxp_isPaused(void) {
    return s_paused.load(std::memory_order_acquire);
}

void mkxp_setSnapshot(const unsigned char *data, int width, int height) {
    std::lock_guard<std::mutex> lock(s_snapshotMutex);
    size_t size = (size_t)width * height * 4;
    s_snapshotData.assign(data, data + size);
    s_snapshotWidth = width;
    s_snapshotHeight = height;
}

const unsigned char *mkxp_getSnapshotRGBA(int *width, int *height) {
    std::lock_guard<std::mutex> lock(s_snapshotMutex);
    if (s_snapshotData.empty()) return nullptr;
    if (width) *width = s_snapshotWidth;
    if (height) *height = s_snapshotHeight;
    return s_snapshotData.data();
}

void mkxp_setPausedCallback(mkxp_PausedCallback cb, void *userdata) {
    s_pausedUserdata = userdata;
    s_pausedCb.store(cb, std::memory_order_release);
}

void mkxp_setResumedCallback(mkxp_ResumedCallback cb, void *userdata) {
    s_resumedUserdata = userdata;
    s_resumedCb.store(cb, std::memory_order_release);
}

void mkxp_setFrameRenderedCallback(mkxp_FrameRenderedCallback cb, void *userdata) {
    s_frameRenderedUserdata = userdata;
    s_frameRenderedCb.store(cb, std::memory_order_release);
}

void mkxp_signalFrameRendered(void) {
    if (s_needsFrameRenderedSignal.exchange(false, std::memory_order_acq_rel)) {
        if (auto cb = s_frameRenderedCb.load(std::memory_order_acquire))
            cb(s_frameRenderedUserdata);
    }
}

// Per-game settings

void mkxp_applyPerGameSettings(MKXPVerticalAlignment verticalAlignment,
                               bool postloadEnabled) {
    int oldAlign = s_verticalAlignment.exchange((int)verticalAlignment, std::memory_order_relaxed);
    if (oldAlign != (int)verticalAlignment) {
        s_safeAreaInsetsChanged.store(true, std::memory_order_release);
    }
    s_postloadEnabled.store(postloadEnabled, std::memory_order_relaxed);
}

MKXPVerticalAlignment mkxp_getVerticalAlignment(void) {
    return (MKXPVerticalAlignment)s_verticalAlignment.load(std::memory_order_relaxed);
}

bool mkxp_getPostloadEnabled(void) {
    return s_postloadEnabled.load(std::memory_order_relaxed);
}

void mkxp_setShowViewportBounds(bool enabled) {
    s_showViewportBounds.store(enabled, std::memory_order_relaxed);
}

bool mkxp_getShowViewportBounds(void) {
    return s_showViewportBounds.load(std::memory_order_relaxed);
}

void mkxp_setViewportBoundsColor(float r, float g, float b, float a) {
    s_vpBoundsR.store(r, std::memory_order_relaxed);
    s_vpBoundsG.store(g, std::memory_order_relaxed);
    s_vpBoundsB.store(b, std::memory_order_relaxed);
    s_vpBoundsA.store(a, std::memory_order_relaxed);
}

void mkxp_getViewportBoundsColor(float *r, float *g, float *b, float *a) {
    if (r) *r = s_vpBoundsR.load(std::memory_order_relaxed);
    if (g) *g = s_vpBoundsG.load(std::memory_order_relaxed);
    if (b) *b = s_vpBoundsB.load(std::memory_order_relaxed);
    if (a) *a = s_vpBoundsA.load(std::memory_order_relaxed);
}

void mkxp_setGLContextBroken(void) {
    s_glContextBroken.store(true, std::memory_order_release);
}

bool mkxp_isGLContextBroken(void) {
    return s_glContextBroken.load(std::memory_order_acquire);
}

MKXPRenderer mkxp_getSelectedRenderer(void) {
#if TARGET_OS_IPHONE
    CFStringRef key = CFSTR("renderer");
    CFStringRef value = (CFStringRef)CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication);
    if (!value) return MKXP_RENDERER_OPENGL_ES;
    bool isANGLE = CFStringCompare(value, CFSTR("angle"), 0) == kCFCompareEqualTo;
    CFRelease(value);
    return isANGLE ? MKXP_RENDERER_ANGLE : MKXP_RENDERER_OPENGL_ES;
#else
    return MKXP_RENDERER_OPENGL_ES;
#endif
}

#if TARGET_OS_IPHONE
extern MKXPRenderer s_currentRenderer;
#endif

MKXPRenderer mkxp_getCurrentRenderer(void) {
#if TARGET_OS_IPHONE
    return s_currentRenderer;
#else
    return MKXP_RENDERER_OPENGL_ES;
#endif
}

const char *mkxp_rendererName(MKXPRenderer renderer) {
    switch (renderer) {
    case MKXP_RENDERER_ANGLE:     return "ANGLE (Metal)";
    case MKXP_RENDERER_OPENGL_ES: return "OpenGL ES";
    default:                      return "Unknown";
    }
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

// Fast-path check so callers in hot paths (resize handler, frame boundary)
// can skip expensive formatting when logging is disabled.
int mkxp_debugLogEnabled(void) {
    // Reading s_debugLogFile without the mutex is safe enough here: the
    // worst outcome is a dropped or duplicated log line if the file is
    // being opened/closed on another thread at the same moment. For a
    // debug log that's acceptable and avoids serializing the entire
    // engine on every hot-path check.
    return s_debugLogFile ? 1 : 0;
}

void mkxp_debugLog(const char *tag, const char *source, const char *message) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    if (!s_debugLogFile) return;
    fprintf(s_debugLogFile, "[%s] (%s) %s\n", tag, source, message);
    // No fflush: let stdio's buffer coalesce writes. The file is flushed
    // when closed in mkxp_setDebugLogPath or at process exit. Flushing
    // on every log line forced a sync write to the sandboxed FS and
    // showed up as a rotation-hitch during profiling.
}

} // extern "C"

// Internal helper — called by binding-mri.cpp, not part of the C bridge.
// Returns empty string if logging is disabled.
std::string mkxp_getDebugLogPath(void) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    return s_debugLogPath;
}
