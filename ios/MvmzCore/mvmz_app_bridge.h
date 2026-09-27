// mvmz_app_bridge.h - the interface a launcher calls the RPG Maker MV
// and MZ core through.
//
// The core answers every name here with the mvmz_ prefix. Empo keeps
// the same interface in GameCore.h under gamecore_, and
// scripts/check-core-interface.sh fails when the two drift. GameCore.h
// says what each name means. This copy keeps only the declarations.

#ifndef MVMZ_APP_BRIDGE_H
#define MVMZ_APP_BRIDGE_H

#include <stdbool.h>

// The framework builds with hidden visibility, so these names are the
// only ones it exports.
#pragma GCC visibility push(default)
enum {
    MVMZ_SCANCODE_UNKNOWN = 0,

    MVMZ_SCANCODE_A = 4,
    MVMZ_SCANCODE_B = 5,
    MVMZ_SCANCODE_C = 6,
    MVMZ_SCANCODE_D = 7,
    MVMZ_SCANCODE_E = 8,
    MVMZ_SCANCODE_F = 9,
    MVMZ_SCANCODE_G = 10,
    MVMZ_SCANCODE_H = 11,
    MVMZ_SCANCODE_I = 12,
    MVMZ_SCANCODE_J = 13,
    MVMZ_SCANCODE_K = 14,
    MVMZ_SCANCODE_L = 15,
    MVMZ_SCANCODE_M = 16,
    MVMZ_SCANCODE_N = 17,
    MVMZ_SCANCODE_O = 18,
    MVMZ_SCANCODE_P = 19,
    MVMZ_SCANCODE_Q = 20,
    MVMZ_SCANCODE_R = 21,
    MVMZ_SCANCODE_S = 22,
    MVMZ_SCANCODE_T = 23,
    MVMZ_SCANCODE_U = 24,
    MVMZ_SCANCODE_V = 25,
    MVMZ_SCANCODE_W = 26,
    MVMZ_SCANCODE_X = 27,
    MVMZ_SCANCODE_Y = 28,
    MVMZ_SCANCODE_Z = 29,

    MVMZ_SCANCODE_1 = 30,
    MVMZ_SCANCODE_2 = 31,
    MVMZ_SCANCODE_3 = 32,
    MVMZ_SCANCODE_4 = 33,
    MVMZ_SCANCODE_5 = 34,
    MVMZ_SCANCODE_6 = 35,
    MVMZ_SCANCODE_7 = 36,
    MVMZ_SCANCODE_8 = 37,
    MVMZ_SCANCODE_9 = 38,
    MVMZ_SCANCODE_0 = 39,

    MVMZ_SCANCODE_RETURN = 40,
    MVMZ_SCANCODE_ESCAPE = 41,
    MVMZ_SCANCODE_BACKSPACE = 42,
    MVMZ_SCANCODE_TAB = 43,
    MVMZ_SCANCODE_SPACE = 44,

    MVMZ_SCANCODE_MINUS = 45,
    MVMZ_SCANCODE_EQUALS = 46,
    MVMZ_SCANCODE_LEFTBRACKET = 47,
    MVMZ_SCANCODE_RIGHTBRACKET = 48,
    MVMZ_SCANCODE_BACKSLASH = 49,
    MVMZ_SCANCODE_SEMICOLON = 51,
    MVMZ_SCANCODE_APOSTROPHE = 52,
    MVMZ_SCANCODE_GRAVE = 53,
    MVMZ_SCANCODE_COMMA = 54,
    MVMZ_SCANCODE_PERIOD = 55,
    MVMZ_SCANCODE_SLASH = 56,

    MVMZ_SCANCODE_F1 = 58,
    MVMZ_SCANCODE_F2 = 59,
    MVMZ_SCANCODE_F3 = 60,
    MVMZ_SCANCODE_F4 = 61,
    MVMZ_SCANCODE_F5 = 62,
    MVMZ_SCANCODE_F6 = 63,
    MVMZ_SCANCODE_F7 = 64,
    MVMZ_SCANCODE_F8 = 65,
    MVMZ_SCANCODE_F9 = 66,
    MVMZ_SCANCODE_F10 = 67,
    MVMZ_SCANCODE_F11 = 68,
    MVMZ_SCANCODE_F12 = 69,

    MVMZ_SCANCODE_RIGHT = 79,
    MVMZ_SCANCODE_LEFT = 80,
    MVMZ_SCANCODE_DOWN = 81,
    MVMZ_SCANCODE_UP = 82,

    MVMZ_SCANCODE_LCTRL = 224,
    MVMZ_SCANCODE_LSHIFT = 225,
    MVMZ_SCANCODE_LALT = 226,

    MVMZ_SCANCODE_HOME = 74,
};

typedef void (*mvmz_EngineTerminatedCallback)(void *userdata);
typedef void (*mvmz_GameRectChangedCallback)(float x, float y, float w, float h, void *userdata);

typedef void (*mvmz_KeyEventCallback)(int scancode, int pressed, void *userdata);

typedef void (*mvmz_TextInputModeCallback)(int active, void *userdata);

typedef void (*mvmz_ErrorMessageCallback)(const char *message, void *userdata);
typedef void (*mvmz_InfoMessageCallback)(const char *message, void *userdata);

typedef void (*mvmz_PausedCallback)(void *userdata);
typedef void (*mvmz_ResumedCallback)(void *userdata);

typedef void (*mvmz_FrameRenderedCallback)(void *userdata);

typedef enum {
    MVMZ_VALIGN_TOP = 0,
    MVMZ_VALIGN_TOP_CENTER = 1,
    MVMZ_VALIGN_CENTER = 2,
} MvmzVerticalAlignment;

typedef struct {
    const char *managedConfigDir;
    const char *userDataDirectory;
    const char *sharedFontsDirectory;
    MvmzVerticalAlignment verticalAlignment;
} MvmzSessionConfig;

#ifdef __cplusplus
extern "C" {
#endif

int mvmz_run_app(int argc, char **argv);

int mvmz_isGameReady(void);

void mvmz_setGamePath(const char *path);
const char *mvmz_waitForGamePath(void);

int mvmz_isEngineTerminated(void);

int mvmz_didEngineExitCleanly(void);

int mvmz_isEngineHung(void);

void mvmz_setEngineTerminatedCallback(mvmz_EngineTerminatedCallback cb, void *userdata);
void mvmz_setGameRectChangedCallback(mvmz_GameRectChangedCallback cb, void *userdata);

void mvmz_injectKeyEvent(int scancode, int pressed);

void mvmz_setConfigOverlayJSON(const char *jsonUTF8);

void mvmz_setLauncherIdentity(const char *name);

void mvmz_setCABundlePath(const char *path);

void mvmz_setTextInputModeCallback(mvmz_TextInputModeCallback cb, void *userdata);
void mvmz_pushTextInput(const char *utf8);
int mvmz_isTextInputActive(void);

double mvmz_getAverageFPS(void);

int mvmz_getTargetFPS(void);

const char *mvmz_getGameTitle(void);

void mvmz_setSafeAreaInsets(float top, float bottom, float left, float right);

void mvmz_setHostViewportRegion(float x, float y, float w, float h, bool isPortrait);

void mvmz_clearHostViewportRegion(void);

void *mvmz_getGameWindow(void);

MvmzVerticalAlignment mvmz_getVerticalAlignment(void);

void mvmz_applySessionConfig(const MvmzSessionConfig *config);

// This core has no keys. Every key writes a warning to the log.
void mvmz_setSetting(const char *key, const char *value);

const char *mvmz_getDetails(void);

void mvmz_setShowViewportBounds(bool enabled);

void mvmz_setCheatsEnabled(bool enabled);
bool mvmz_getCheatsEnabled(void);

void mvmz_setGameControllerCaptureEnabled(bool enabled);

void mvmz_setTouchMouseEnabled(bool enabled);

void mvmz_setViewportBoundsColor(float r, float g, float b, float a);

void mvmz_presentErrorAndWait(const char *message);

void mvmz_signalErrorDismissed(void);

void mvmz_setErrorMessageCallback(mvmz_ErrorMessageCallback cb, void *userdata);

void mvmz_presentInfoAndWait(const char *message);

void mvmz_signalInfoDismissed(void);

void mvmz_setInfoMessageCallback(mvmz_InfoMessageCallback cb, void *userdata);

void mvmz_requestPause(void);
void mvmz_requestResume(void);

bool mvmz_isPaused(void);

bool mvmz_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height);

bool mvmz_getSnapshotSize(int *width, int *height);

void mvmz_setPausedCallback(mvmz_PausedCallback cb, void *userdata);
void mvmz_setResumedCallback(mvmz_ResumedCallback cb, void *userdata);
void mvmz_setFrameRenderedCallback(mvmz_FrameRenderedCallback cb, void *userdata);

void mvmz_setFastForwardMultiplier(int multiplier);
int mvmz_getFastForwardMultiplier(void);

void mvmz_resetSessionState(void);

// Removes the web view. WebKit ends the page and all of its
// JavaScript with it.
void mvmz_killSession(void);

void mvmz_setDebugLogPath(const char *path);

#ifdef __cplusplus
}
#endif

#pragma GCC visibility pop

#endif  // MVMZ_APP_BRIDGE_H
