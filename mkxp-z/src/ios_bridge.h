// ios_bridge.h — C-linkage bridge between mkxp-z engine and iOS UI layer.
//
// This header is the ONLY interface between the engine and the UI.
// The UI side must not import any engine headers (SDL, SharedState, etc.).
// The engine side must not import any UI headers (UIKit, SwiftUI, etc.).
// Both sides communicate exclusively through these functions.

#ifndef IOS_BRIDGE_H
#define IOS_BRIDGE_H

#include <stdbool.h>
// ============================================================================
// Scancode constants
// ============================================================================
//
// Platform-independent key identifiers used by the input bridge.
// Numeric values match SDL_Scancode (USB HID usage page 0x07) so the
// engine can pass them straight through without translation.
// UI code should use these constants instead of importing SDL headers.

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

// ============================================================================
// Game lifecycle
// ============================================================================

void        mkxp_setGameReady(void);
int         mkxp_isGameReady(void);

// ============================================================================
// Game selection (Library -> Engine)
// ============================================================================

// mkxp_setGamePath: called by the Library when the user picks a game.
// mkxp_waitForGamePath: blocks until mkxp_setGamePath is called, returns the path.
void        mkxp_setGamePath(const char *path);
const char *mkxp_waitForGamePath(void);

// ============================================================================
// Engine termination
// ============================================================================

// mkxp_requestTerminate: UI asks the engine to shut down.
// mkxp_isTerminateRequested: check if termination was requested (before engine has shut down).
// mkxp_isEngineTerminated: check if the engine has fully shut down.
// mkxp_setEngineTerminated: engine sets this after teardown is complete.
// mkxp_resetBridgeState: resets all bridge flags for a new game session.
void        mkxp_requestTerminate(void);
int         mkxp_isTerminateRequested(void);
int         mkxp_isEngineTerminated(void);
void        mkxp_setEngineTerminated(void);
void        mkxp_resetBridgeState(void);

// ============================================================================
// Lifecycle callbacks (Engine -> UI)
// ============================================================================
//
// These callbacks fire on the engine thread when state changes.
// The UI side must dispatch to the main thread for any UI updates.

// Called when the engine finishes loading and the game starts rendering.
typedef void (*mkxp_GameReadyCallback)(void *userdata);
void        mkxp_setGameReadyCallback(mkxp_GameReadyCallback cb, void *userdata);

// Called when the engine has fully shut down after a quit request.
typedef void (*mkxp_EngineTerminatedCallback)(void *userdata);
void        mkxp_setEngineTerminatedCallback(mkxp_EngineTerminatedCallback cb, void *userdata);

// Called when the game viewport rect changes (x, y, w, h in logical points).
typedef void (*mkxp_GameRectChangedCallback)(float x, float y, float w, float h, void *userdata);
void        mkxp_setGameRectChangedCallback(mkxp_GameRectChangedCallback cb, void *userdata);

// ============================================================================
// Input injection (UI -> Engine)
// ============================================================================

// Injects a key press/release event into the engine's input queue.
// scancode: an MKXP_SCANCODE_* value.
// pressed: 1 for key down, 0 for key up.
void        mkxp_injectKeyEvent(int scancode, int pressed);

// ============================================================================
// Key event callback (Engine -> UI)
// ============================================================================

// Called on a background thread when the engine processes a hardware key event.
// The UI should dispatch to the main thread for any UI updates.
typedef void (*mkxp_KeyEventCallback)(int scancode, int pressed, void *userdata);
void        mkxp_setKeyEventCallback(mkxp_KeyEventCallback cb, void *userdata);

// ============================================================================
// Engine state queries
// ============================================================================

double      mkxp_getAverageFPS(void);
int         mkxp_getRGSSVersion(void);
const char *mkxp_getGameTitle(void);

// ============================================================================
// Game viewport rect (logical points)
// ============================================================================

// mkxp_setGameRect: called by the engine when viewport changes.
// mkxp_getGameRect: called by the UI to read the current game area.
void        mkxp_setGameRect(float x, float y, float w, float h);
void        mkxp_getGameRect(float *x, float *y, float *w, float *h);

// ============================================================================
// UI system queries (implemented in systemImplIOS.mm)
// ============================================================================

// Safe area insets in logical points (read from cached atomics).
void        mkxp_getSafeAreaInsets(float *top, float *bottom, float *left, float *right);

// Push safe area insets from UIKit. Call from main thread whenever insets change.
// Also sets a "needs relayout" flag so the engine recalculates its viewport.
void        mkxp_setSafeAreaInsets(float top, float bottom, float left, float right);

// Returns true (once) if safe area insets changed since last check.
// The engine polls this each frame to trigger viewport recalculation.
bool        mkxp_consumeSafeAreaInsetsChanged(void);

// UIKit screen scale factor (e.g. 3.0 on iPhone Pro).
// Use this instead of SDL's backingScaleFactor when converting UIKit points to GL pixels.
float       mkxp_getScreenScale(void);

// ============================================================================
// Per-game settings (UI -> Engine, set before each session)
// ============================================================================
//
// These are set by selectGame() before mkxp_setGamePath() and read by the
// engine during the session. They must NOT be reset in mkxp_resetBridgeState()
// because selectGame() always sets them explicitly before each session.
//
// To add a new per-game bridge setting:
//   1. Add a parameter to mkxp_applyPerGameSettings() below
//   2. Add an atomic in ios_bridge.cpp with a getter
//   3. Add the field to GameSettings.swift and pass it from AppState.selectGame()

typedef enum {
    MKXP_VALIGN_TOP        = 0,
    MKXP_VALIGN_TOP_CENTER = 1,
    MKXP_VALIGN_CENTER     = 2,
} MKXPVerticalAlignment;

void        mkxp_applyPerGameSettings(MKXPVerticalAlignment verticalAlignment,
                                      bool postloadEnabled);

MKXPVerticalAlignment mkxp_getVerticalAlignment(void);

// Postload scripts toggle: whether to run engine postload scripts.
bool        mkxp_getPostloadEnabled(void);

// Whether to show the viewport bounds by tinting the area outside the game.
void        mkxp_setShowViewportBounds(bool enabled);
bool        mkxp_getShowViewportBounds(void);

// Set/get the viewport bounds color (RGBA, 0.0–1.0).
void        mkxp_setViewportBoundsColor(float r, float g, float b, float a);
void        mkxp_getViewportBoundsColor(float *r, float *g, float *b, float *a);

// ============================================================================
// Error routing (Engine -> UI)
// ============================================================================

// On iOS, SDL_ShowSimpleMessageBox is a no-op.  Route error messages
// through the bridge so the UI can present them.
void        mkxp_setErrorMessage(const char *message);
const char *mkxp_getErrorMessage(void);

// Called when the engine sets an error message.
typedef void (*mkxp_ErrorMessageCallback)(const char *message, void *userdata);
void        mkxp_setErrorMessageCallback(mkxp_ErrorMessageCallback cb, void *userdata);

// ============================================================================
// Pause / Resume (UI <-> Engine)
// ============================================================================
//
// Pause flow:
//   1. UI calls mkxp_requestPause().
//   2. Engine calls mkxp_checkPause() from Graphics blocking points.
//      It pauses all audio sources, fires the paused callback, then
//      blocks on a condvar.
//   3. UI calls mkxp_requestResume() to unblock the engine thread.

// UI -> Engine: request the engine to pause/resume.
void        mkxp_requestPause(void);
void        mkxp_requestResume(void);

// Engine -> internal: check if a pause was requested, pause audio, and block.
// Called from Graphics blocking points. NOT for UI use.
void        mkxp_checkPause(void);

// Query pause state.
bool        mkxp_isPauseRequested(void);
bool        mkxp_isPaused(void);

// Snapshot: RGBA pixel data captured by the engine before blocking.
// mkxp_getSnapshotRGBA returns a pointer to the pixel buffer (valid until
// the next pause). Width/height are set by the engine.
// The UI must NOT free this pointer.
void        mkxp_setSnapshot(const unsigned char *data, int width, int height);
const unsigned char *mkxp_getSnapshotRGBA(int *width, int *height);

// Called on the engine thread when the engine has actually paused
// (snapshot captured, audio suspended, thread about to block).
typedef void (*mkxp_PausedCallback)(void *userdata);
void        mkxp_setPausedCallback(mkxp_PausedCallback cb, void *userdata);

// Called on the engine thread when the engine has resumed.
typedef void (*mkxp_ResumedCallback)(void *userdata);
void        mkxp_setResumedCallback(mkxp_ResumedCallback cb, void *userdata);

// ============================================================================
// Debug logging
// ============================================================================

// mkxp_setDebugLogPath: set the file path for debug logging this session.
// Pass NULL or "" to disable logging. Called by UI before each game session.
void        mkxp_setDebugLogPath(const char *path);

// mkxp_debugLog: append a log line to the debug log file (if enabled).
// tag: short category (e.g. "SESSION", "SCRIPT", "FATAL")
// source: file and language identifier (e.g. "binding-mri.cpp [C++]")
// message: the log message
// No-op if debug logging is disabled.
void        mkxp_debugLog(const char *tag, const char *source, const char *message);

#ifdef __cplusplus
}
#endif

#endif // IOS_BRIDGE_H
