// Answers GameCore.h with the host interface of the mkxp-z engine
// release that cores/mkxp/.version pins. The engine names each function
// mkxp_ and passes scancodes as SDL_Scancode, which GAMECORE_SCANCODE_*
// matches.

#include "GameCore.h"
#include "app_bridge.h"

int gamecore_run_app(int argc, char **argv) {
    return mkxp_run_app(argc, argv);
}

int gamecore_isGameReady(void) {
    return mkxp_isGameReady();
}

void gamecore_setGamePath(const char *path) {
    mkxp_setGamePath(path);
}

int gamecore_isEngineTerminated(void) {
    return mkxp_isEngineTerminated();
}

int gamecore_didEngineExitCleanly(void) {
    return mkxp_didEngineExitCleanly();
}

int gamecore_isEngineHung(void) {
    return mkxp_isEngineHung();
}

void gamecore_setEngineTerminatedCallback(gamecore_EngineTerminatedCallback cb, void *userdata) {
    mkxp_setEngineTerminatedCallback(cb, userdata);
}

void gamecore_setGameRectChangedCallback(gamecore_GameRectChangedCallback cb, void *userdata) {
    mkxp_setGameRectChangedCallback(cb, userdata);
}

void gamecore_injectKeyEvent(int scancode, int pressed) {
    mkxp_injectKeyEvent(scancode, pressed);
}

void gamecore_setConfigOverlayJSON(const char *jsonUTF8) {
    mkxp_setConfigOverlayJSON(jsonUTF8);
}

void gamecore_setLauncherIdentity(const char *name) {
    mkxp_setLauncherIdentity(name);
}

void gamecore_setCABundlePath(const char *path) {
    mkxp_setCABundlePath(path);
}

void gamecore_setTextInputModeCallback(gamecore_TextInputModeCallback cb, void *userdata) {
    mkxp_setTextInputModeCallback(cb, userdata);
}

void gamecore_pushTextInput(const char *utf8) {
    mkxp_pushTextInput(utf8);
}

int gamecore_isTextInputActive(void) {
    return mkxp_isTextInputActive();
}

double gamecore_getAverageFPS(void) {
    return mkxp_getAverageFPS();
}

int gamecore_getTargetFPS(void) {
    return mkxp_getTargetFPS();
}

const char *gamecore_getGameTitle(void) {
    return mkxp_getGameTitle();
}

void gamecore_setSafeAreaInsets(float top, float bottom, float left, float right) {
    mkxp_setSafeAreaInsets(top, bottom, left, right);
}

void gamecore_setHostViewportRegion(float x, float y, float w, float h, bool isPortrait) {
    mkxp_setHostViewportRegion(x, y, w, h, isPortrait);
}

void gamecore_clearHostViewportRegion(void) {
    mkxp_clearHostViewportRegion();
}

void *gamecore_getGameWindow(void) {
    return mkxp_getGameWindow();
}

GameCoreVerticalAlignment gamecore_getVerticalAlignment(void) {
    return (GameCoreVerticalAlignment)mkxp_getVerticalAlignment();
}

void gamecore_applySessionConfig(const GameCoreSessionConfig *config) {
    MKXPSessionConfig mkxp = {
        .managedConfigDir = "",
        .userDataDirectory = config->userDataDirectory,
        .sharedFontsDirectory = config->sharedFontsDirectory,
        .verticalAlignment = (MKXPVerticalAlignment)config->verticalAlignment,
    };
    mkxp_applySessionConfig(&mkxp);
}

// The keys are the ones app_bridge.h lists for mkxp_setSetting.
void gamecore_setSetting(const char *key, const char *value) {
    mkxp_setSetting(key, value);
}

const char *gamecore_getDetails(void) {
    return mkxp_getDetails();
}

void gamecore_setShowViewportBounds(bool enabled) {
    mkxp_setShowViewportBounds(enabled);
}

void gamecore_setCheatsEnabled(bool enabled) {
    mkxp_setCheatsEnabled(enabled);
}

bool gamecore_getCheatsEnabled(void) {
    return mkxp_getCheatsEnabled();
}

void gamecore_setGameControllerCaptureEnabled(bool enabled) {
    mkxp_setGameControllerCaptureEnabled(enabled);
}

void gamecore_setTouchMouseEnabled(bool enabled) {
    mkxp_setTouchMouseEnabled(enabled);
}

void gamecore_setViewportBoundsColor(float r, float g, float b, float a) {
    mkxp_setViewportBoundsColor(r, g, b, a);
}

void gamecore_signalErrorDismissed(void) {
    mkxp_signalErrorDismissed();
}

void gamecore_setErrorMessageCallback(gamecore_ErrorMessageCallback cb, void *userdata) {
    mkxp_setErrorMessageCallback(cb, userdata);
}

void gamecore_signalInfoDismissed(void) {
    mkxp_signalInfoDismissed();
}

void gamecore_setInfoMessageCallback(gamecore_InfoMessageCallback cb, void *userdata) {
    mkxp_setInfoMessageCallback(cb, userdata);
}

void gamecore_requestPause(void) {
    mkxp_requestPause();
}

void gamecore_requestResume(void) {
    mkxp_requestResume();
}

bool gamecore_isPaused(void) {
    return mkxp_isPaused();
}

bool gamecore_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height) {
    return mkxp_copySnapshotRGBA(dest, destSize, width, height);
}

bool gamecore_getSnapshotSize(int *width, int *height) {
    return mkxp_getSnapshotSize(width, height);
}

void gamecore_setPausedCallback(gamecore_PausedCallback cb, void *userdata) {
    mkxp_setPausedCallback(cb, userdata);
}

void gamecore_setResumedCallback(gamecore_ResumedCallback cb, void *userdata) {
    mkxp_setResumedCallback(cb, userdata);
}

void gamecore_setFrameRenderedCallback(gamecore_FrameRenderedCallback cb, void *userdata) {
    mkxp_setFrameRenderedCallback(cb, userdata);
}

void gamecore_setFastForwardMultiplier(int multiplier) {
    mkxp_setFastForwardMultiplier(multiplier);
}

int gamecore_getFastForwardMultiplier(void) {
    return mkxp_getFastForwardMultiplier();
}

void gamecore_resetSessionState(void) {
    mkxp_resetSessionState();
}

void gamecore_killSession(void) {
    mkxp_killSession();
}

void gamecore_setDebugLogPath(const char *path) {
    mkxp_setDebugLogPath(path);
}
