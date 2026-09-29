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

// Scancode constants. Values match SDL_Scancode (USB HID usage page
// 0x07) so the engine passes them through without translation. UI
// code uses these instead of importing SDL headers.

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

// Lifecycle callbacks (Engine -> UI). Fire on the engine thread. UI
// must dispatch to main for any UI updates.
typedef void (*gamecore_EngineTerminatedCallback)(void *userdata);
typedef void (*gamecore_GameRectChangedCallback)(float x, float y, float w, float h, void *userdata);

// Key event callback (Engine -> UI, fires on background thread)
typedef void (*gamecore_KeyEventCallback)(int scancode, int pressed, void *userdata);

// Text-input mode callback (Engine -> UI). See the text-input bridge
// section below.
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

// Runs the engine on the calling thread, which must be the main
// thread. It returns when the game ends.
//
// Call it from a run loop callout, never from a block on the main
// dispatch queue. The engine holds the thread for the whole session,
// so the queue would never drain, and a core that dispatch_syncs to
// it deadlocks.
int gamecore_run_app(int argc, char **argv);

// Game lifecycle

int gamecore_isGameReady(void);

// Game selection (Library -> Engine)

void gamecore_setGamePath(const char *path);

// Engine termination

int gamecore_isEngineTerminated(void);

// Set when the session ends because Ruby raised SystemExit (e.g. the
// game's "Exit to desktop" menu). The UI checks this in its
// engine-terminated callback to skip the "didn't exit cleanly" alert.
int gamecore_didEngineExitCleanly(void);

// Set when the RGSS thread failed to respond to a termination
// request. Engine is unrecoverable. The UI surfaces a "close from
// app switcher" alert because we can't recover in-process.
int gamecore_isEngineHung(void);

void gamecore_setEngineTerminatedCallback(gamecore_EngineTerminatedCallback cb, void *userdata);
void gamecore_setGameRectChangedCallback(gamecore_GameRectChangedCallback cb, void *userdata);

// Input injection (UI -> Engine)

// scancode: GAMECORE_SCANCODE_* value. pressed: 1=down, 0=up.
void gamecore_injectKeyEvent(int scancode, int pressed);

// In-memory config overlay (UI -> Engine).
//
// A JSON object of mkxp.json keys. A core that reads mkxp.json merges
// it over the game's own file at config-read time. Another core reads
// the display keys it knows and ignores the rest. Overlay keys win per TOP-LEVEL key (shallow merge: an
// overlay `bindingNames` replaces the whole object). JSON null
// values neutralize a key so the engine's guarded reads fall back to
// defaults. Lets hosts override config keys per session without
// mutating the developer's on-disk file. Same idea as the existing
// per-session bridge setters, generalized.
//
// Set before each session start. NULL or "" clears any previous
// overlay. Reject inputs over 1 MiB (warn log, keep previous state).
void gamecore_setConfigOverlayJSON(const char *jsonUTF8);

// Per-game UserData directory (UI -> Engine).
//
// On iOS, hosts store game writable payload in a per-game container
// (e.g. `Documents/Games/<id>/UserData/`) so saves and companion
// files are visible in the Files app and travel with the rest of the
// imported container. Games that use app-data helpers
// (`System.data_directory`, `MKXP.data_directory`, fake APPDATA env)
// and games that use relative RGSS save filenames are both routed
// here by the engine + preload compatibility layer.

// Shared fonts directory (UI -> Engine).
//
// A host-wide font pool, shared by every game the way the Windows
// system font folder is. The engine mounts it under the virtual
// "Fonts" mountpoint (game-own files keep priority) so its fonts
// load for every game, and the preload compatibility layer routes
// Windows-style "<SystemRoot>\Fonts\<file>" writes (Essentials'
// FontInstaller) into it. Unset = no shared pool. Per-game fonts
// only.

// Launcher identity (UI -> Engine).
//
// Name of the host launcher embedding the engine, exposed to game
// scripts before any preload/game code runs:
//
//   $userAgent = "<name>"
//   $<name>    = true     (only when the name is a valid Ruby
//                          identifier: [A-Za-z_][A-Za-z0-9_]*)
//
// This is the same detection contract JoiPlay established with its
// `$joiplay` global. Each host declares its own name so games and
// patches can branch on the specific launcher. Set once before the
// engine boots. Pass NULL/"" to clear (no globals are defined).
void gamecore_setLauncherIdentity(const char *name);

// CA certificate bundle (UI -> Engine).
//
// Absolute path to a PEM CA bundle (e.g. the Mozilla root store)
// used to verify TLS server certificates for all engine-side
// networking: the native HTTPLite client, and Ruby's openssl ext
// (exported as SSL_CERT_FILE before the VM boots). Set once before
// the engine starts, like the launcher identity.
//
// When unset, TLS connections fail closed (certificate verification
// has no roots to succeed against). Plain http still works.
void gamecore_setCABundlePath(const char *path);

// Text-input bridge (UI <-> Engine).
//
// Games request text input via `Input.text_input = true`, which calls
// `SDL_StartTextInput()` inside EventThread. The mode callback fires
// from the main thread on state changes. iOS uses it to auto-show
// the system keyboard.
//
// `gamecore_pushTextInput` is the inverse: the soft keyboard's
// UITextField delegate forwards typed UTF-8 strings here, wrapped as
// SDL_TEXTINPUT events and read by Ruby `Input.gets`. Strings longer
// than SDL's 32-byte per-event limit are chunked at UTF-8 boundaries.
//
// `gamecore_isTextInputActive()` lets the UI skip pushing events when SDL
// text mode is off (otherwise the buffer fills with input nobody reads).
void gamecore_setTextInputModeCallback(gamecore_TextInputModeCallback cb, void *userdata);
void gamecore_pushTextInput(const char *utf8);
int gamecore_isTextInputActive(void);

// Engine state queries

double gamecore_getAverageFPS(void);

// The frame rate the game asks for (`Graphics.frame_rate`). Games
// set their own cap: RPG Maker XP games usually run at 40, VX and
// VX Ace games at 60. The host compares the average FPS against
// this number to tell "full speed" from "slow". Returns 0 when no
// game runs.
int gamecore_getTargetFPS(void);

const char *gamecore_getGameTitle(void);

// Safe area insets (logical points, cached atomics)

// Push from UIKit main thread. Sets a "needs relayout" flag.
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
// Sets the relayout flag. The engine applies the region at its next
// relayout poll.
void gamecore_setHostViewportRegion(float x, float y, float w, float h, bool isPortrait);

// Back to automatic placement, as if no region was ever set.
void gamecore_clearHostViewportRegion(void);

// The UIWindow* the game draws in, or NULL before the core creates it.
// Owned by the core. Do not retain. For embedding host controls in the
// same window stack as the game view on iOS.
void *gamecore_getGameWindow(void);

// Per-game settings (UI -> Engine), set by the host before engine
// boot and read by the engine during the run.
//
// Prefer `gamecore_applySessionConfig()` for pre-boot settings. It
// groups the fields the host sets together on every launch. Individual
// setters remain for mid-session toggles and legacy call sites.

GameCoreVerticalAlignment gamecore_getVerticalAlignment(void);

void gamecore_applySessionConfig(const GameCoreSessionConfig *config);

// A per-game setting that only the open core knows (UI -> Engine).
// The launcher sends each one as text before it calls
// gamecore_applySessionConfig. The core's bridge lists its keys and
// values. An unknown key writes a warning to the
// log and changes nothing.
void gamecore_setSetting(const char *key, const char *value);

// Lines about the running engine for the debug overlay, one per line.
// Call it on the main thread. The text stays valid until the next call.
// Empty when the core has nothing to add.
const char *gamecore_getDetails(void);

// Adding a new per-boot setting: give it a key in the core's
// setSetting. Add a field to GameCoreSessionConfig only when every
// core needs it.

void gamecore_setShowViewportBounds(bool enabled);

// Cheat menu toggle (UI -> Engine). The postload layer reads the
// current value each update. Ruby reassigns $CHEATS from the bridge
// so the toggle takes effect mid-game without re-entering scripts.
void gamecore_setCheatsEnabled(bool enabled);
bool gamecore_getCheatsEnabled(void);

/* Controls whether the engine consumes SDL game-controller events
 * for its built-in input bindings. Hosts that implement their own
 * physical-controller handling disable this to avoid double input.
 * Default: enabled. Must be set before or during session start.
 * Takes effect immediately. */
void gamecore_setGameControllerCaptureEnabled(bool enabled);

/* Controls whether touch-synthesized SDL mouse events
 * (which == SDL_TOUCH_MOUSEID) are delivered to the engine input
 * layer. Default: false = upstream behavior (touch never synthesizes
 * mouse input). Hosts that want touch-as-mouse set it true. */
void gamecore_setTouchMouseEnabled(bool enabled);

void gamecore_setViewportBoundsColor(float r, float g, float b, float a);

// Error routing (Engine -> UI). The core calls the error callback and
// blocks its engine thread until the UI calls
// gamecore_signalErrorDismissed.
void gamecore_signalErrorDismissed(void);

void gamecore_setErrorMessageCallback(gamecore_ErrorMessageCallback cb, void *userdata);

// Info-message routing (Engine -> UI). Games show a notice (PE 20+
// version banners, plugin dialogs) and then keep running. This is not
// an error: the UI shows a plain alert. The core calls the info
// callback and blocks its engine thread until the UI calls
// gamecore_signalInfoDismissed.
void gamecore_signalInfoDismissed(void);

void gamecore_setInfoMessageCallback(gamecore_InfoMessageCallback cb, void *userdata);

// Pause / Resume (UI <-> Engine).
//   1. UI calls `gamecore_requestPause()`
//   2. The engine, at a Graphics blocking point, pauses audio, fires the paused callback, and blocks
//      on a condvar
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

// Runtime fast-forward multiplier. When > 1 the FPS limiter scales
// target ticks-per-frame down so the game paces N times faster.
// Toggleable live without restart. Range: 1 (off) or 2-9 (active).
void gamecore_setFastForwardMultiplier(int multiplier);
int gamecore_getFastForwardMultiplier(void);

// Reset all per-session host-bridge state to engine defaults. Called
// once before each new game launch so values from the previous
// session (fast-forward multiplier, cheats flag) don't leak.
//
// Per-session = bridge fields that vary per game. Globally-persistent state (viewport
// bounds debug overlay etc., owned by app-level Settings UI) is NOT
// touched.
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
