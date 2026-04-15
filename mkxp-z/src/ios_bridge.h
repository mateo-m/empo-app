// ios_bridge.h — C-linkage bridge between mkxp-z engine and iOS UI layer.
//
// This header is the ONLY interface between the engine and the UI.
// The UI side must not import any engine headers (SDL, SharedState, etc.).
// The engine side must not import any UI headers (UIKit, SwiftUI, etc.).
// Both sides communicate exclusively through these functions.

#ifndef IOS_BRIDGE_H
#define IOS_BRIDGE_H

#include <stdbool.h>
// Scancode constants
//
// Values match SDL_Scancode (USB HID usage page 0x07) so the engine
// can pass them through without translation. UI code should use these
// instead of importing SDL headers.

enum {
    MKXP_SCANCODE_UNKNOWN   = 0,

    // Letters
    MKXP_SCANCODE_A = 4,  MKXP_SCANCODE_B = 5,  MKXP_SCANCODE_C = 6,
    MKXP_SCANCODE_D = 7,  MKXP_SCANCODE_E = 8,  MKXP_SCANCODE_F = 9,
    MKXP_SCANCODE_G = 10, MKXP_SCANCODE_H = 11, MKXP_SCANCODE_I = 12,
    MKXP_SCANCODE_J = 13, MKXP_SCANCODE_K = 14, MKXP_SCANCODE_L = 15,
    MKXP_SCANCODE_M = 16, MKXP_SCANCODE_N = 17, MKXP_SCANCODE_O = 18,
    MKXP_SCANCODE_P = 19, MKXP_SCANCODE_Q = 20, MKXP_SCANCODE_R = 21,
    MKXP_SCANCODE_S = 22, MKXP_SCANCODE_T = 23, MKXP_SCANCODE_U = 24,
    MKXP_SCANCODE_V = 25, MKXP_SCANCODE_W = 26, MKXP_SCANCODE_X = 27,
    MKXP_SCANCODE_Y = 28, MKXP_SCANCODE_Z = 29,

    // Digits
    MKXP_SCANCODE_1 = 30, MKXP_SCANCODE_2 = 31, MKXP_SCANCODE_3 = 32,
    MKXP_SCANCODE_4 = 33, MKXP_SCANCODE_5 = 34, MKXP_SCANCODE_6 = 35,
    MKXP_SCANCODE_7 = 36, MKXP_SCANCODE_8 = 37, MKXP_SCANCODE_9 = 38,
    MKXP_SCANCODE_0 = 39,

    // Control / whitespace
    MKXP_SCANCODE_RETURN    = 40,
    MKXP_SCANCODE_ESCAPE    = 41,
    MKXP_SCANCODE_BACKSPACE = 42,
    MKXP_SCANCODE_TAB       = 43,
    MKXP_SCANCODE_SPACE     = 44,

    // Punctuation / symbols
    MKXP_SCANCODE_MINUS        = 45,
    MKXP_SCANCODE_EQUALS       = 46,
    MKXP_SCANCODE_LEFTBRACKET  = 47,
    MKXP_SCANCODE_RIGHTBRACKET = 48,
    MKXP_SCANCODE_BACKSLASH    = 49,
    MKXP_SCANCODE_SEMICOLON    = 51,
    MKXP_SCANCODE_APOSTROPHE   = 52,
    MKXP_SCANCODE_GRAVE        = 53,
    MKXP_SCANCODE_COMMA        = 54,
    MKXP_SCANCODE_PERIOD       = 55,
    MKXP_SCANCODE_SLASH        = 56,

    // Function keys
    MKXP_SCANCODE_F1  = 58, MKXP_SCANCODE_F2  = 59, MKXP_SCANCODE_F3  = 60,
    MKXP_SCANCODE_F4  = 61, MKXP_SCANCODE_F5  = 62, MKXP_SCANCODE_F6  = 63,
    MKXP_SCANCODE_F7  = 64, MKXP_SCANCODE_F8  = 65, MKXP_SCANCODE_F9  = 66,
    MKXP_SCANCODE_F10 = 67, MKXP_SCANCODE_F11 = 68, MKXP_SCANCODE_F12 = 69,

    // Arrow keys
    MKXP_SCANCODE_RIGHT = 79,
    MKXP_SCANCODE_LEFT  = 80,
    MKXP_SCANCODE_DOWN  = 81,
    MKXP_SCANCODE_UP    = 82,

    // Modifiers
    MKXP_SCANCODE_LCTRL  = 224,
    MKXP_SCANCODE_LSHIFT = 225,
    MKXP_SCANCODE_LALT   = 226,
};

#ifdef __cplusplus
extern "C" {
#endif

// Game lifecycle

void        mkxp_setGameReady(void);
int         mkxp_isGameReady(void);

// Game selection (Library -> Engine)

void        mkxp_setGamePath(const char *path);
const char *mkxp_waitForGamePath(void);

// Engine termination

void        mkxp_requestTerminate(void);
int         mkxp_isEngineTerminated(void);
void        mkxp_setEngineTerminated(void);
void        mkxp_resetBridgeState(void);

// Lifecycle callbacks (Engine -> UI)
//
// Fire on the engine thread. UI must dispatch to main for any updates.

typedef void (*mkxp_EngineTerminatedCallback)(void *userdata);
void        mkxp_setEngineTerminatedCallback(mkxp_EngineTerminatedCallback cb, void *userdata);

typedef void (*mkxp_GameRectChangedCallback)(float x, float y, float w, float h, void *userdata);
void        mkxp_setGameRectChangedCallback(mkxp_GameRectChangedCallback cb, void *userdata);

// Input injection (UI -> Engine)

// scancode: MKXP_SCANCODE_* value. pressed: 1=down, 0=up.
void        mkxp_injectKeyEvent(int scancode, int pressed);

// Key event callback (Engine -> UI, fires on background thread)

typedef void (*mkxp_KeyEventCallback)(int scancode, int pressed, void *userdata);
void        mkxp_setKeyEventCallback(mkxp_KeyEventCallback cb, void *userdata);

// Engine state queries

double      mkxp_getAverageFPS(void);
int         mkxp_getRGSSVersion(void);
const char *mkxp_getGameTitle(void);

// Game viewport rect (logical points)

void        mkxp_setGameRect(float x, float y, float w, float h);

// Safe area insets (logical points, cached atomics)

void        mkxp_getSafeAreaInsets(float *top, float *bottom, float *left, float *right);

// Push from UIKit main thread. Sets a "needs relayout" flag.
void        mkxp_setSafeAreaInsets(float top, float bottom, float left, float right);

// Returns true (once) if insets changed since last check.
bool        mkxp_consumeSafeAreaInsetsChanged(void);

// Screen scale factor (e.g. 3.0 on iPhone Pro).
float       mkxp_getScreenScale(void);

// Per-game settings (UI -> Engine, set before each session)
//
// Set by selectGame() before mkxp_setGamePath(), read by the engine
// during the session. NOT reset in mkxp_resetBridgeState() — selectGame()
// always sets them explicitly.
//
// To add a new setting:
//   1. Add a parameter to mkxp_applyPerGameSettings()
//   2. Add an atomic + getter in ios_bridge.cpp
//   3. Add the field to GameSettings.swift, pass from AppState.selectGame()

typedef enum {
    MKXP_VALIGN_TOP        = 0,
    MKXP_VALIGN_TOP_CENTER = 1,
    MKXP_VALIGN_CENTER     = 2,
} MKXPVerticalAlignment;

void        mkxp_applyPerGameSettings(MKXPVerticalAlignment verticalAlignment,
                                      bool postloadEnabled);

MKXPVerticalAlignment mkxp_getVerticalAlignment(void);
bool        mkxp_getPostloadEnabled(void);

void        mkxp_setShowViewportBounds(bool enabled);
bool        mkxp_getShowViewportBounds(void);

void        mkxp_setViewportBoundsColor(float r, float g, float b, float a);
void        mkxp_getViewportBoundsColor(float *r, float *g, float *b, float *a);

// Error routing (Engine -> UI)
//
// SDL_ShowSimpleMessageBox is a no-op on iOS, so errors are routed
// through the bridge for the UI to present.

void        mkxp_setErrorMessage(const char *message);

typedef void (*mkxp_ErrorMessageCallback)(const char *message, void *userdata);
void        mkxp_setErrorMessageCallback(mkxp_ErrorMessageCallback cb, void *userdata);

// Pause / Resume (UI <-> Engine)
//
// Flow:
//   1. UI calls mkxp_requestPause()
//   2. Engine calls mkxp_checkPause() from Graphics blocking points —
//      pauses audio, fires paused callback, blocks on condvar
//   3. UI calls mkxp_requestResume() to unblock

void        mkxp_requestPause(void);
void        mkxp_requestResume(void);

// Engine-internal: checks for pause request, blocks if needed. NOT for UI.
void        mkxp_checkPause(void);

bool        mkxp_isPauseRequested(void);
bool        mkxp_isPaused(void);

// Snapshot: RGBA pixel buffer captured before blocking. Valid until
// next pause. The UI must NOT free this pointer.
void        mkxp_setSnapshot(const unsigned char *data, int width, int height);
const unsigned char *mkxp_getSnapshotRGBA(int *width, int *height);

// Fires on engine thread when paused (snapshot captured, audio suspended).
typedef void (*mkxp_PausedCallback)(void *userdata);
void        mkxp_setPausedCallback(mkxp_PausedCallback cb, void *userdata);

typedef void (*mkxp_ResumedCallback)(void *userdata);
void        mkxp_setResumedCallback(mkxp_ResumedCallback cb, void *userdata);

// One-shot: fires on engine thread after first frame is swapped post-resume
// (or fresh start). UI uses this to fade the snapshot / dismiss loading.
typedef void (*mkxp_FrameRenderedCallback)(void *userdata);
void        mkxp_setFrameRenderedCallback(mkxp_FrameRenderedCallback cb, void *userdata);

// Engine-internal: fires the one-shot frame-rendered signal. NOT for UI.
void        mkxp_signalFrameRendered(void);

// GL context crash detection (set by SDL layer on caught SIGSEGV/SIGBUS).

void        mkxp_setGLContextBroken(void);
bool        mkxp_isGLContextBroken(void);

// Debug logging

// Set log file path for this session (NULL/"" to disable).
void        mkxp_setDebugLogPath(const char *path);

// Append a tagged log line (no-op if disabled).
void        mkxp_debugLog(const char *tag, const char *source, const char *message);

#ifdef __cplusplus
}
#endif

#endif // IOS_BRIDGE_H
