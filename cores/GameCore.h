// GameCore.h - the interface a launcher calls a game core through.
//
// Every core implements each function here under this exact name, in
// its own bridge: cores/<core>/<core>_app_bridge.*. The bridge includes
// this file, so the compiler checks every signature. Each core links
// with the export list that cores/gamecore-exports.sh writes from this
// file, so the linker fails when a bridge leaves a function out, and
// the core exports nothing else.
//
// The launcher links no core. It opens the core of the game that the
// person picked with dlopen, and calls these names in that image.

#ifndef GAME_CORE_H
#define GAME_CORE_H

#include <stdbool.h>

// Key codes. Each value is the USB HID usage ID of the key on the
// keyboard page (0x07).

enum {
    GAMECORE_SCANCODE_UNKNOWN = 0,

    // Letters
    GAMECORE_SCANCODE_A = 4,
    GAMECORE_SCANCODE_B = 5,
    GAMECORE_SCANCODE_C = 6,
    GAMECORE_SCANCODE_D = 7,
    GAMECORE_SCANCODE_E = 8,
    GAMECORE_SCANCODE_F = 9,
    GAMECORE_SCANCODE_G = 10,
    GAMECORE_SCANCODE_H = 11,
    GAMECORE_SCANCODE_I = 12,
    GAMECORE_SCANCODE_J = 13,
    GAMECORE_SCANCODE_K = 14,
    GAMECORE_SCANCODE_L = 15,
    GAMECORE_SCANCODE_M = 16,
    GAMECORE_SCANCODE_N = 17,
    GAMECORE_SCANCODE_O = 18,
    GAMECORE_SCANCODE_P = 19,
    GAMECORE_SCANCODE_Q = 20,
    GAMECORE_SCANCODE_R = 21,
    GAMECORE_SCANCODE_S = 22,
    GAMECORE_SCANCODE_T = 23,
    GAMECORE_SCANCODE_U = 24,
    GAMECORE_SCANCODE_V = 25,
    GAMECORE_SCANCODE_W = 26,
    GAMECORE_SCANCODE_X = 27,
    GAMECORE_SCANCODE_Y = 28,
    GAMECORE_SCANCODE_Z = 29,

    // Digits
    GAMECORE_SCANCODE_1 = 30,
    GAMECORE_SCANCODE_2 = 31,
    GAMECORE_SCANCODE_3 = 32,
    GAMECORE_SCANCODE_4 = 33,
    GAMECORE_SCANCODE_5 = 34,
    GAMECORE_SCANCODE_6 = 35,
    GAMECORE_SCANCODE_7 = 36,
    GAMECORE_SCANCODE_8 = 37,
    GAMECORE_SCANCODE_9 = 38,
    GAMECORE_SCANCODE_0 = 39,

    // Control / whitespace
    GAMECORE_SCANCODE_RETURN = 40,
    GAMECORE_SCANCODE_ESCAPE = 41,
    GAMECORE_SCANCODE_BACKSPACE = 42,
    GAMECORE_SCANCODE_TAB = 43,
    GAMECORE_SCANCODE_SPACE = 44,

    // Punctuation / symbols
    GAMECORE_SCANCODE_MINUS = 45,
    GAMECORE_SCANCODE_EQUALS = 46,
    GAMECORE_SCANCODE_LEFTBRACKET = 47,
    GAMECORE_SCANCODE_RIGHTBRACKET = 48,
    GAMECORE_SCANCODE_BACKSLASH = 49,
    GAMECORE_SCANCODE_SEMICOLON = 51,
    GAMECORE_SCANCODE_APOSTROPHE = 52,
    GAMECORE_SCANCODE_GRAVE = 53,
    GAMECORE_SCANCODE_COMMA = 54,
    GAMECORE_SCANCODE_PERIOD = 55,
    GAMECORE_SCANCODE_SLASH = 56,

    // Function keys
    GAMECORE_SCANCODE_F1 = 58,
    GAMECORE_SCANCODE_F2 = 59,
    GAMECORE_SCANCODE_F3 = 60,
    GAMECORE_SCANCODE_F4 = 61,
    GAMECORE_SCANCODE_F5 = 62,
    GAMECORE_SCANCODE_F6 = 63,
    GAMECORE_SCANCODE_F7 = 64,
    GAMECORE_SCANCODE_F8 = 65,
    GAMECORE_SCANCODE_F9 = 66,
    GAMECORE_SCANCODE_F10 = 67,
    GAMECORE_SCANCODE_F11 = 68,
    GAMECORE_SCANCODE_F12 = 69,

    // Arrow keys
    GAMECORE_SCANCODE_RIGHT = 79,
    GAMECORE_SCANCODE_LEFT = 80,
    GAMECORE_SCANCODE_DOWN = 81,
    GAMECORE_SCANCODE_UP = 82,

    // Modifiers
    GAMECORE_SCANCODE_LCTRL = 224,
    GAMECORE_SCANCODE_LSHIFT = 225,
    GAMECORE_SCANCODE_LALT = 226,

    // Navigation
    GAMECORE_SCANCODE_HOME = 74,
};

// Lifecycle callbacks (Engine -> UI). They fire on a core thread. The UI
// must dispatch to main for any UI updates.
typedef void (*gamecore_EngineTerminatedCallback)(void *userdata);
typedef void (*gamecore_GameRectChangedCallback)(float x, float y, float w, float h, void *userdata);

// Key event callback (Engine -> UI, fires on background thread)
typedef void (*gamecore_KeyEventCallback)(int scancode, int pressed, void *userdata);

// Text-input mode callback (Engine -> UI). See the text input section
// below.
typedef void (*gamecore_TextInputModeCallback)(int active, void *userdata);

typedef void (*gamecore_ErrorMessageCallback)(const char *message, void *userdata);
typedef void (*gamecore_InfoMessageCallback)(const char *message, void *userdata);

// Fires on engine thread when paused (snapshot captured, audio suspended).
typedef void (*gamecore_PausedCallback)(void *userdata);
typedef void (*gamecore_ResumedCallback)(void *userdata);

// One-shot: fires on engine thread after first frame is swapped post-resume
// (or fresh start). UI uses this to fade the snapshot / dismiss loading.
typedef void (*gamecore_FrameRenderedCallback)(void *userdata);

typedef enum {
    GAMECORE_VALIGN_TOP = 0,
    GAMECORE_VALIGN_TOP_CENTER = 1,
    GAMECORE_VALIGN_CENTER = 2,
} GameCoreVerticalAlignment;

typedef struct {
    const char *userDataDirectory;
    const char *sharedFontsDirectory;
    GameCoreVerticalAlignment verticalAlignment;
} GameCoreSessionConfig;

#ifdef __cplusplus
extern "C" {
#endif

// Process entry (Launcher -> Engine)

// Runs the core with the process arguments, on the calling thread,
// which must be the main thread. A core may hold the thread until the
// game ends, or return at once and run the game on its own threads.
//
// Call it from a run loop callout, never from a block on the main
// dispatch queue. A core that holds the thread would stop the queue,
// and a core that dispatch_syncs to it would deadlock.
int gamecore_run_app(int argc, char **argv);

// Game lifecycle

int gamecore_isGameReady(void);

// Game selection (Library -> Engine)

void gamecore_setGamePath(const char *path);

// Engine termination

int gamecore_isEngineTerminated(void);

// True when the game ended itself, for example from its own "Exit"
// menu item. The UI checks this in its engine-terminated callback to
// skip the "didn't exit cleanly" alert.
int gamecore_didEngineExitCleanly(void);

// True when the game thread did not stop after a stop request. The
// core cannot recover, so the UI tells the person to close the app
// from the app switcher.
int gamecore_isEngineHung(void);

void gamecore_setEngineTerminatedCallback(gamecore_EngineTerminatedCallback cb, void *userdata);
void gamecore_setGameRectChangedCallback(gamecore_GameRectChangedCallback cb, void *userdata);

// Input injection (UI -> Engine)

// scancode: GAMECORE_SCANCODE_* value. pressed: 1=down, 0=up.
void gamecore_injectKeyEvent(int scancode, int pressed);

// GameCoreSessionConfig.userDataDirectory is a folder that the launcher
// gives the game for its saves and other files. A core that has no
// place of its own for these files writes them to this folder. A core
// whose game keeps its files in its own folder ignores it.
//
// GameCoreSessionConfig.sharedFontsDirectory is a font folder that all
// games share, like the system font folder of a desktop. A core that
// loads fonts from files loads these after the game's own fonts. NULL
// means no shared folder.

// The launcher's name (UI -> Engine). A core that lets a game ask which
// launcher runs it gives the game this name. Set it once before the
// game starts. NULL or "" clears it.
void gamecore_setLauncherIdentity(const char *name);

// CA certificate bundle (UI -> Engine).
//
// The absolute path to a PEM CA bundle, for example the Mozilla root
// store. A core that makes its own TLS connections checks the server
// certificates with it. A core that uses the system network stack
// ignores it. Set it once before the game starts.
//
// When it is not set, the core's own TLS connections fail, because no
// root can verify a certificate. Plain http still works.
void gamecore_setCABundlePath(const char *path);

// Text input (UI <-> Engine).
//
// The mode callback fires on the main thread when the game starts or
// stops to ask for text. The UI shows or hides the system keyboard.
//
// `gamecore_pushTextInput` sends the typed text to the game as UTF-8,
// in strings of any length.
//
// `gamecore_isTextInputActive()` tells the UI if the game reads text
// now, so the UI sends no text that nobody reads.
void gamecore_setTextInputModeCallback(gamecore_TextInputModeCallback cb, void *userdata);
void gamecore_pushTextInput(const char *utf8);
int gamecore_isTextInputActive(void);

// Engine state queries

double gamecore_getAverageFPS(void);

// The frame rate that the core aims for. A core that reads the game's
// own rate returns it, often 40 or 60, and 0 when no game runs. A core
// with a fixed rate always returns that rate. The UI compares the
// average FPS with this number to tell "full speed" from "slow".
int gamecore_getTargetFPS(void);

const char *gamecore_getGameTitle(void);

// Safe area insets (logical points, cached atomics)

// Call it on the main thread. The core applies the insets at its next
// layout pass.
void gamecore_setSafeAreaInsets(float top, float bottom, float left, float right);

// Host viewport region (dimensionless window fractions)
//
// The host may confine the game picture to a sub-rectangle of the
// window. x/y/w/h are fractions of the window in [0,1], top-left
// origin. isPortrait tags the orientation the region was computed
// for. The engine draws automatic placement while the window
// orientation does not match (rotation safety). With fixed aspect
// ratio on (the default), the picture aspect-fits centered inside
// the region. With it off, the picture stretches to fill the
// region, mirroring the no-region path. The vertical-alignment
// preset and the safe-area insets apply only on the no-region path.
// The core applies the region at its next layout pass.
void gamecore_setHostViewportRegion(float x, float y, float w, float h, bool isPortrait);

// Back to automatic placement, as if no region was ever set.
void gamecore_clearHostViewportRegion(void);

// The UIWindow* the game draws in, or NULL before the core creates it.
// Owned by the core. Do not retain. For embedding host controls in the
// same window stack as the game view on iOS.
void *gamecore_getGameWindow(void);

// Per-game settings (UI -> Engine). The launcher sets them before the
// game starts, and the core reads them during the run.

GameCoreVerticalAlignment gamecore_getVerticalAlignment(void);

void gamecore_applySessionConfig(const GameCoreSessionConfig *config);

// A per-game setting that only some cores know (UI -> Engine). The
// launcher sends each one as text before it calls
// gamecore_applySessionConfig. The core's bridge lists its keys and
// values. An unknown key writes a warning to the log and changes
// nothing. Add a field to GameCoreSessionConfig only when every core
// needs it.
void gamecore_setSetting(const char *key, const char *value);

// Lines about the running engine for the debug overlay, one per line.
// Call it on the main thread. The text stays valid until the next call.
// Empty when the core has nothing to add.
const char *gamecore_getDetails(void);

void gamecore_setShowViewportBounds(bool enabled);

// Cheat menu toggle (UI -> Engine). The change applies while the game
// runs.
void gamecore_setCheatsEnabled(bool enabled);
bool gamecore_getCheatsEnabled(void);

// True lets the core read game controllers with its own key bindings.
// A launcher that reads the controllers itself sets false, so that no
// press arrives twice. The default is true. The change applies at once.
void gamecore_setGameControllerCaptureEnabled(bool enabled);

// True makes a touch act as the mouse for the game. The default is
// false.
void gamecore_setTouchMouseEnabled(bool enabled);

void gamecore_setViewportBoundsColor(float r, float g, float b, float a);

// Error routing (Engine -> UI). The UI shows the message in an alert
// and calls gamecore_signalErrorDismissed when the person closes it. A
// core that waits for that blocks its engine thread until the call. A
// core that does not wait ignores it, and a core with no messages never
// calls the callback.
void gamecore_signalErrorDismissed(void);

void gamecore_setErrorMessageCallback(gamecore_ErrorMessageCallback cb, void *userdata);

// Info-message routing (Engine -> UI). Games show a notice, for example
// a version banner, and then keep running. This is not
// an error: the UI shows a plain alert and calls
// gamecore_signalInfoDismissed when the person closes it. The same
// rules as for errors apply.
void gamecore_signalInfoDismissed(void);

void gamecore_setInfoMessageCallback(gamecore_InfoMessageCallback cb, void *userdata);

// Pause / Resume (UI <-> Engine).
//   1. UI calls `gamecore_requestPause()`
//   2. At its next frame, the core pauses audio, fires the paused
//      callback, and waits
//   3. UI calls `gamecore_requestResume()` to unblock

void gamecore_requestPause(void);
void gamecore_requestResume(void);

bool gamecore_isPaused(void);

// Copy the snapshot into `dest` (must be at least width*height*4 bytes).
// Returns true if a snapshot was available, false if empty.
bool gamecore_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height);

// Returns the snapshot dimensions without copying. Use to pre-allocate
// the buffer for gamecore_copySnapshotRGBA.
bool gamecore_getSnapshotSize(int *width, int *height);

void gamecore_setPausedCallback(gamecore_PausedCallback cb, void *userdata);
void gamecore_setResumedCallback(gamecore_ResumedCallback cb, void *userdata);
void gamecore_setFrameRenderedCallback(gamecore_FrameRenderedCallback cb, void *userdata);

// Fast-forward multiplier. At N > 1 the game runs N times faster. The
// change applies while the game runs. Range: 1 (off) or 2-9 (on).
void gamecore_setFastForwardMultiplier(int multiplier);
int gamecore_getFastForwardMultiplier(void);

// Resets the per-game state to the core defaults, for example the
// fast-forward multiplier and the cheats flag. The launcher calls it
// before each game starts. App-wide state, such as the viewport bounds
// overlay, stays.
void gamecore_resetSessionState(void);

// Kills the running game and frees everything it made. After this call
// the core holds nothing of that game, so the launcher may start any
// game next, on this core or on another one. The launcher calls it only
// for a core that can do this. A core that cannot stops the process
// instead.
void gamecore_killSession(void);

// Debug logging

// Set log file path for this session (NULL/"" to disable).
void gamecore_setDebugLogPath(const char *path);

#ifdef __cplusplus
}
#endif

#endif  // GAME_CORE_H
