// The launcher interface for the PSDK core.
//
// A launcher opens one core and calls it through the psdk_* names
// psdk_app_bridge.h declares. This file answers them with the calls of
// psdk_core.h, the interface of one libpsdk<NN>.a from
// mateo-m/psdk-apple-mobile.
//
// Four things here do real work: the game thread, the frame callback,
// the picture placement and the pause. The rest stores what the
// launcher pushes or gives a fixed answer. Every function that gives
// less than a full answer says so where it is.

#include "psdk_app_bridge.h"
#include "psdk_core.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <libgen.h>
#include <mutex>
#include <pthread.h>
#include <stdlib.h>
#include <string>
#include <time.h>
#include <unistd.h>
#include <vector>

#include <GLES2/gl2.h>

namespace {

std::mutex gLock;
std::string gGamePath;
std::string gLauncherIdentity;
std::string gCABundlePath;
std::string gDebugLogPath;
std::string gConfigOverlayJSON;

// pthread_cond, not a dispatch semaphore. psdk_waitForGamePath runs on
// the game thread and the launcher sets the path from the main thread.
pthread_mutex_t gPathMutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t gPathReady = PTHREAD_COND_INITIALIZER;

struct Callback {
    void *fn = nullptr;
    void *userdata = nullptr;
};

Callback gFrameRendered;
Callback gEngineTerminated;
Callback gGameRectChanged;
Callback gErrorMessage;
Callback gInfoMessage;
Callback gPaused;
Callback gResumed;
Callback gTextInputMode;

// The core carries the game's keyboard request out through a plain C
// callback, and the launcher takes it through psdk_TextInputModeCallback.
// This turns one into the other.
void forwardTextInputMode(int active, void *) {
    if (gTextInputMode.fn) {
        reinterpret_cast<psdk_TextInputModeCallback>(gTextInputMode.fn)(active, gTextInputMode.userdata);
    }
}

// Where the picture goes. The launcher gives a region of its window, the
// game gives its own resolution, and placeOutputRegion turns the two into
// the region SFML draws in. Every input arrives on its own, so each one
// stores its value and calls placeOutputRegion again.
std::atomic<bool> gHasHostRegion{false};
std::atomic<bool> gHostRegionPortrait{false};
std::atomic<float> gHostRegionX{0.0f};
std::atomic<float> gHostRegionY{0.0f};
std::atomic<float> gHostRegionW{1.0f};
std::atomic<float> gHostRegionH{1.0f};
std::atomic<int> gGameWidth{0};
std::atomic<int> gGameHeight{0};
std::atomic<bool> gFixedAspectRatio{true};
// The safe area, in points, as the launcher last reported it. Automatic
// placement keeps the picture clear of the notch and the home indicator.
std::atomic<float> gSafeTop{0.0f};
std::atomic<float> gSafeBottom{0.0f};
std::atomic<float> gSafeLeft{0.0f};
std::atomic<float> gSafeRight{0.0f};
std::atomic<int> gVerticalAlignment{PSDK_VALIGN_TOP_CENTER};
// The window size the last placement used, width in the high half and
// height in the low half.
std::atomic<unsigned long long> gPlacedWindowSize{0};
// Where the picture landed, in window pixels. The snapshot reads it.
std::atomic<int> gPictureX{0};
std::atomic<int> gPictureY{0};
std::atomic<int> gPictureW{0};
std::atomic<int> gPictureH{0};

std::atomic<bool> gGameReady{false};
std::atomic<bool> gEngineTerminatedFlag{false};
std::atomic<bool> gExitedCleanly{false};
std::atomic<bool> gPausedFlag{false};
std::mutex gPauseLock;
std::condition_variable gResumeSignal;
// The frame the launcher shows while the pause menu is up. Non-empty
// exactly while a pause holds a captured frame: the frame hook fills it
// on the first frame after the request, and resume empties it.
std::mutex gSnapshotLock;
std::vector<unsigned char> gSnapshotRGBA;
int gSnapshotW = 0;
int gSnapshotH = 0;
std::atomic<bool> gCheatsEnabled{false};
std::atomic<bool> gShowViewportBounds{false};
std::atomic<bool> gControllerCaptureEnabled{false};
std::atomic<int> gFastForwardMultiplier{1};
// Drawn frames, and the clock and the count the last read took. The
// average covers the time between two reads, so a reader that asks once
// a second gets the last second.
std::atomic<unsigned long long> gDrawnFrames{0};
std::atomic<unsigned long long> gFpsMarkFrames{0};
std::atomic<double> gFpsMarkSeconds{0.0};
std::atomic<int> gArgc{0};
std::atomic<char **> gArgv{nullptr};

// Ruby's parser and the PSDK boot scripts recurse deeply. The default
// 512 KB worker stack overflows. mkxp-z gives its RGSS thread the same
// 16 MB.
constexpr size_t kGameStackBytes = 16 * 1024 * 1024;

// The core reads its own files from its own bundle, so a launcher embeds
// the framework and ships no PSDK file of its own. dladdr on a
// function in this image names the framework binary, and its folder is
// the bundle. mkxp-z finds its assets the same way
// (filesystemImplIOS.mm mkxpOwnBundle).
std::string ownBundlePath() {
    Dl_info info;
    if (dladdr(reinterpret_cast<const void *>(&ownBundlePath), &info) == 0 || !info.dli_fname) {
        return {};
    }
    std::string path(info.dli_fname);
    std::string copy(path);
    return dirname(&copy[0]);
}

void *runGame(void *) {
    const std::string bundle = ownBundlePath();
    const std::string support = bundle + "/PsdkSupport";
    const char *path = psdk_waitForGamePath();

    int result = psdk_run(gArgc.load(), gArgv.load(), path, support.c_str(), nullptr);
    fprintf(stderr, "[psdk-bridge] psdk_run returned %d\n", result);

    gExitedCleanly.store(result == PSDK_OK);
    gEngineTerminatedFlag.store(true);
    if (gEngineTerminated.fn) {
        reinterpret_cast<psdk_EngineTerminatedCallback>(gEngineTerminated.fn)(
            gEngineTerminated.userdata);
    }
    return nullptr;
}

} // namespace

namespace {

// A launcher switch out of the same overlay it gives mkxp-z. A missing
// key means the default. This reads one key instead of parsing the whole
// document. mkxp-z reads some of these keys as a number and some as a
// boolean, so Empo writes `"smoothScaling": 1` but `"fixedAspectRatio":
// true`. Both forms mean on here.
bool readFlagKey(const std::string &json, const std::string &key, bool fallback) {
    const size_t keyAt = json.find("\"" + key + "\"");
    if (keyAt == std::string::npos) {
        return fallback;
    }
    const size_t colonAt = json.find(':', keyAt);
    if (colonAt == std::string::npos) {
        return fallback;
    }
    const size_t at = json.find_first_not_of(" \t\r\n", colonAt + 1);
    if (at == std::string::npos) {
        return fallback;
    }
    if (json.compare(at, 4, "true") == 0) {
        return true;
    }
    if (json.compare(at, 5, "false") == 0) {
        return false;
    }
    if (json[at] == '-' || (json[at] >= '0' && json[at] <= '9')) {
        return std::strtod(json.c_str() + at, nullptr) != 0.0;
    }
    return fallback;
}

// The core answers 0 until the game makes its window. A scale of 0
// would divide the game rect by zero, so the first placement reads 1.
float backingScale() {
    const float scale = psdk_backing_scale();
    return scale > 0.0f ? scale : 1.0f;
}

// Puts the picture in the launcher's region and tells the launcher where
// it landed.
//
// The region is a fraction of the window, so the fit needs the window in
// pixels and the game's resolution. Either one may still be missing: the
// launcher sets its region before the game starts, and the game reports
// its resolution when it opens its window. Whichever arrives last does
// the work.
void placeOutputRegion() {
    unsigned int windowW = 0;
    unsigned int windowH = 0;
    psdk_window_pixel_size(&windowW, &windowH);
    const int gameW = gGameWidth.load();
    const int gameH = gGameHeight.load();
    if (windowW == 0 || windowH == 0 || gameW <= 0 || gameH <= 0) {
        return;
    }

    const bool windowIsPortrait = windowH > windowW;

    float x = 0.0f;
    float y = 0.0f;
    float w = 1.0f;
    float h = 1.0f;
    bool hostRegionApplies = false;
    if (gHasHostRegion.load()) {
        // Rotation safety: the launcher sets one region for each
        // orientation. A region tagged for the other one belongs to the
        // rotation that has not landed yet, so the whole window holds the
        // picture until the matching call arrives. mkxp-z reads the same
        // tag for the same reason.
        if (gHostRegionPortrait.load() == windowIsPortrait) {
            hostRegionApplies = true;
            x = gHostRegionX.load();
            y = gHostRegionY.load();
            w = gHostRegionW.load();
            h = gHostRegionH.load();
        }
    }

    if (!hostRegionApplies) {
        // Automatic placement. The launcher clamps its own region to the
        // safe area before it sends one, so the insets apply on this path
        // only. mkxp-z states the same rule in app_bridge.h, and the
        // launcher's reset animation aims at this rect, so the two must
        // give the same answer (ScreenPresetPlacement.swift).
        //
        // The launcher sends the insets in points and the window
        // measures in pixels, so the insets take the backing scale.
        const float scale = backingScale();
        const float left = gSafeLeft.load() * scale;
        const float right = gSafeRight.load() * scale;
        x = left / static_cast<float>(windowW);
        w = 1.0f - (left + right) / static_cast<float>(windowW);
        if (windowIsPortrait) {
            // Landscape keeps the full height, so the picture stays as
            // large as the screen permits. mkxp-z makes the same choice.
            const float top = gSafeTop.load() * scale;
            const float bottom = gSafeBottom.load() * scale;
            y = top / static_cast<float>(windowH);
            h = 1.0f - (top + bottom) / static_cast<float>(windowH);
        }
    }

    // Clamp before the fit, so a region that reaches past the window
    // cannot push the picture outside it.
    x = std::max(0.0f, std::min(1.0f, x));
    y = std::max(0.0f, std::min(1.0f, y));
    w = std::max(0.0f, std::min(1.0f - x, w));
    h = std::max(0.0f, std::min(1.0f - y, h));
    if (w <= 0.0f || h <= 0.0f) {
        return;
    }

    const float boxY = y;
    const float boxH = h;

    if (gFixedAspectRatio.load()) {
        // Keep the game's proportions: fit the picture in the region and
        // center what is left. Without this the picture stretches to the
        // region, which is the whole screen by default.
        const float regionW = w * static_cast<float>(windowW);
        const float regionH = h * static_cast<float>(windowH);
        const float gameRatio = static_cast<float>(gameW) / static_cast<float>(gameH);
        float pictureW = regionW;
        float pictureH = regionW / gameRatio;
        if (pictureH > regionH) {
            pictureH = regionH;
            pictureW = regionH * gameRatio;
        }
        const float newW = pictureW / static_cast<float>(windowW);
        const float newH = pictureH / static_cast<float>(windowH);
        x += (w - newW) / 2.0f;
        y += (h - newH) / 2.0f;
        w = newW;
        h = newH;
    }

    if (!hostRegionApplies && windowIsPortrait) {
        // The fit above centered the picture in the safe box. Top pins it
        // to the top of the box, and top-center sits halfway between the
        // two. Landscape keeps the centered fit for every setting.
        const float topY = boxY;
        const float centerY = boxY + (boxH - h) / 2.0f;
        switch (gVerticalAlignment.load()) {
        case PSDK_VALIGN_TOP:
            y = topY;
            break;
        case PSDK_VALIGN_CENTER:
            y = centerY;
            break;
        default:
            y = (topY + centerY) / 2.0f;
            break;
        }
    }

    psdk_set_output_region(x, y, w, h);

    gPictureX.store(static_cast<int>(x * static_cast<float>(windowW)));
    gPictureY.store(static_cast<int>(y * static_cast<float>(windowH)));
    gPictureW.store(static_cast<int>(w * static_cast<float>(windowW)));
    gPictureH.store(static_cast<int>(h * static_cast<float>(windowH)));

    if (gGameRectChanged.fn) {
        // The launcher draws its touch controls in points, so the rect
        // leaves in points.
        const float scale = backingScale();
        reinterpret_cast<psdk_GameRectChangedCallback>(gGameRectChanged.fn)(
            x * static_cast<float>(windowW) / scale, y * static_cast<float>(windowH) / scale,
            w * static_cast<float>(windowW) / scale, h * static_cast<float>(windowH) / scale,
            gGameRectChanged.userdata);
    }
}

// Reads the frame the game just drew, for the pause menu behind it.
// The core calls the frame callback before the swap, so the default
// framebuffer still holds the picture here.
//
// The launcher asks for the snapshot from the paused callback, which
// fires below only after this returns, so it can never ask for a frame
// that does not exist yet.
void captureSnapshot() {
    const int x = gPictureX.load();
    const int y = gPictureY.load();
    const int w = gPictureW.load();
    const int h = gPictureH.load();
    unsigned int windowW = 0;
    unsigned int windowH = 0;
    psdk_window_pixel_size(&windowW, &windowH);
    if (w <= 0 || h <= 0 || windowH == 0) {
        return;
    }
    const size_t stride = static_cast<size_t>(w) * 4;
    std::vector<unsigned char> rows(stride * static_cast<size_t>(h));
    // glReadPixels counts rows from the bottom of the window.
    // placeOutputRegion measures the picture from the top.
    glReadPixels(x, static_cast<int>(windowH) - y - h, w, h, GL_RGBA, GL_UNSIGNED_BYTE,
                 rows.data());
    std::lock_guard<std::mutex> lock(gSnapshotLock);
    gSnapshotRGBA.resize(stride * static_cast<size_t>(h));
    for (int row = 0; row < h; ++row) {
        memcpy(gSnapshotRGBA.data() + stride * static_cast<size_t>(row),
               rows.data() + stride * static_cast<size_t>(h - 1 - row), stride);
    }
    gSnapshotW = w;
    gSnapshotH = h;
}

// The core calls this with the resolution the game asked for, when the
// game opens its window and when it changes the resolution.
void onGameResolution(long width, long height, void *) {
    gGameWidth.store(static_cast<int>(width));
    gGameHeight.store(static_cast<int>(height));
    placeOutputRegion();
}

// The core calls this on the game thread for every frame, before the
// swap.
void onFrame(void *) {
    // The game reports its resolution from DisplayWindow.new, which runs
    // before SFML makes the window, so that first placement has no
    // window to measure and does nothing. A drawn frame proves the
    // window exists. The size also changes on every rotation, so the
    // check reads the size itself instead of a "first frame" flag.
    unsigned int windowW = 0;
    unsigned int windowH = 0;
    psdk_window_pixel_size(&windowW, &windowH);
    const unsigned long long size =
        (static_cast<unsigned long long>(windowW) << 32) | static_cast<unsigned long long>(windowH);
    if (size != 0 && gPlacedWindowSize.exchange(size) != size) {
        fprintf(stderr, "[psdk-bridge] window %ux%u px\n", windowW, windowH);
        placeOutputRegion();
    }

    gDrawnFrames.fetch_add(1);

    bool first = !gGameReady.exchange(true);
    if (first) {
        // The window size says which picture the screen got. A phone that
        // reports fewer pixels than its screen has drew a small picture
        // and let iOS stretch it, and every glyph loses pixels.
        fprintf(stderr, "[psdk-bridge] first frame, window %ux%u px, scale %.1f\n",
                windowW, windowH, psdk_backing_scale());
    }
    if (gFrameRendered.fn) {
        reinterpret_cast<psdk_FrameRenderedCallback>(gFrameRendered.fn)(gFrameRendered.userdata);
    }

    // The pause menu opens on this callback, so it opens one frame after
    // the request, with the frame it shows already stored. The game
    // thread then waits here, before the swap, until the resume.
    std::unique_lock<std::mutex> lock(gPauseLock);
    if (!gPausedFlag.load()) {
        return;
    }
    captureSnapshot();
    psdk_pause_audio();
    if (gPaused.fn) {
        reinterpret_cast<psdk_PausedCallback>(gPaused.fn)(gPaused.userdata);
    }
    // PSDK's FPSBalancer counts frames from the microsecond part of the
    // clock. So after a pause of any length, the game catches up less
    // than one second of updates.
    gResumeSignal.wait(lock, [] { return !gPausedFlag.load(); });
    psdk_resume_audio();
}

} // namespace

// MARK: - Starting the game

// Starts the game on its own thread and returns at once.
//
// MkxpCore holds the calling thread here until the game ends. This core
// cannot: SFML marshals every UIKit call to the main thread with
// dispatch_sync, so the main thread has to stay in its run loop and
// answer them. A launcher reads psdk_isEngineTerminated or takes the
// terminated callback either way.
int psdk_run_app(int argc, char **argv) {
    gArgc.store(argc);
    gArgv.store(argv);
    psdk_set_frame_callback(onFrame, nullptr);
    psdk_set_resolution_callback(onGameResolution, nullptr);

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, kGameStackBytes);
    pthread_t thread;
    int created = pthread_create(&thread, &attr, runGame, nullptr);
    pthread_attr_destroy(&attr);
    if (created != 0) {
        fprintf(stderr, "[psdk-bridge] cannot start the game thread\n");
        return -1;
    }
    pthread_detach(thread);
    return 0;
}

void psdk_setGamePath(const char *path) {
    pthread_mutex_lock(&gPathMutex);
    gGamePath = path ? path : "";
    pthread_cond_broadcast(&gPathReady);
    pthread_mutex_unlock(&gPathMutex);
}

const char *psdk_waitForGamePath(void) {
    pthread_mutex_lock(&gPathMutex);
    while (gGamePath.empty()) {
        pthread_cond_wait(&gPathReady, &gPathMutex);
    }
    // The string never changes again in one session, so the pointer
    // stays valid after the unlock.
    const char *path = gGamePath.c_str();
    pthread_mutex_unlock(&gPathMutex);
    return path;
}

// MARK: - Input

// The launcher's scancodes are USB HID usages, which the core takes.
void psdk_injectKeyEvent(int scancode, int pressed) { psdk_inject_key(scancode, pressed); }

// MARK: - The window

void *psdk_getGameWindow(void) { return psdk_game_window(); }

// MARK: - Callbacks

void psdk_setFrameRenderedCallback(psdk_FrameRenderedCallback cb, void *userdata) {
    gFrameRendered = {reinterpret_cast<void *>(cb), userdata};
}

void psdk_setEngineTerminatedCallback(psdk_EngineTerminatedCallback cb, void *userdata) {
    gEngineTerminated = {reinterpret_cast<void *>(cb), userdata};
}

void psdk_setGameRectChangedCallback(psdk_GameRectChangedCallback cb, void *userdata) {
    gGameRectChanged = {reinterpret_cast<void *>(cb), userdata};
}

void psdk_setErrorMessageCallback(psdk_ErrorMessageCallback cb, void *userdata) {
    gErrorMessage = {reinterpret_cast<void *>(cb), userdata};
}

void psdk_setInfoMessageCallback(psdk_InfoMessageCallback cb, void *userdata) {
    gInfoMessage = {reinterpret_cast<void *>(cb), userdata};
}

void psdk_setPausedCallback(psdk_PausedCallback cb, void *userdata) {
    gPaused = {reinterpret_cast<void *>(cb), userdata};
}

void psdk_setResumedCallback(psdk_ResumedCallback cb, void *userdata) {
    gResumed = {reinterpret_cast<void *>(cb), userdata};
}

void psdk_setTextInputModeCallback(psdk_TextInputModeCallback cb, void *userdata) {
    gTextInputMode = {reinterpret_cast<void *>(cb), userdata};
    psdk_set_keyboard_callback(cb ? forwardTextInputMode : nullptr, nullptr);
}

// MARK: - Session state

int psdk_isGameReady(void) { return gGameReady.load() ? 1 : 0; }
int psdk_isEngineTerminated(void) { return gEngineTerminatedFlag.load() ? 1 : 0; }
int psdk_didEngineExitCleanly(void) { return gExitedCleanly.load() ? 1 : 0; }

// MkxpCore watches its own RGSS thread for a stall. Nothing here does,
// so a hung PSDK game reads as running.
//
// ponytail: the signal would be the frame counter above going quiet for
// a few seconds. Add it when a real hang shows up.
int psdk_isEngineHung(void) { return 0; }

// A Ruby VM cannot be torn down and started again in one process, so
// this core cannot kill a game. Empo never calls this for it.
void psdk_killSession(void) {
    fprintf(stderr, "[psdk] killSession: this core cannot kill a game\n");
    abort();
}

void psdk_resetSessionState(void) {
    // One core runs for each process and Empo plays one game for each
    // process, so this never runs twice with a game behind it.
    gGameReady.store(false);
    gEngineTerminatedFlag.store(false);
    gExitedCleanly.store(false);
    gPausedFlag.store(false);
    gHasHostRegion.store(false);
    gGameWidth.store(0);
    gGameHeight.store(0);
    gPlacedWindowSize.store(0);
    gPictureW.store(0);
    gPictureH.store(0);
    std::lock_guard<std::mutex> lock(gSnapshotLock);
    gSnapshotRGBA.clear();
    gSnapshotW = 0;
    gSnapshotH = 0;
}

// MARK: - Pause

// onFrame stops the game thread and the audio.
void psdk_requestPause(void) { gPausedFlag.store(true); }

void psdk_requestResume(void) {
    {
        std::lock_guard<std::mutex> lock(gPauseLock);
        gPausedFlag.store(false);
    }
    gResumeSignal.notify_one();
    {
        std::lock_guard<std::mutex> lock(gSnapshotLock);
        gSnapshotRGBA.clear();
        gSnapshotW = 0;
        gSnapshotH = 0;
    }
    if (gResumed.fn) {
        reinterpret_cast<psdk_ResumedCallback>(gResumed.fn)(gResumed.userdata);
    }
}

bool psdk_isPaused(void) { return gPausedFlag.load(); }

// MARK: - Snapshots

bool psdk_getSnapshotSize(int *width, int *height) {
    std::lock_guard<std::mutex> lock(gSnapshotLock);
    if (gSnapshotRGBA.empty()) {
        return false;
    }
    if (width) *width = gSnapshotW;
    if (height) *height = gSnapshotH;
    return true;
}

bool psdk_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height) {
    std::lock_guard<std::mutex> lock(gSnapshotLock);
    if (dest == nullptr || gSnapshotRGBA.empty()) {
        return false;
    }
    if (destSize < 0 || static_cast<size_t>(destSize) < gSnapshotRGBA.size()) {
        return false;
    }
    memcpy(dest, gSnapshotRGBA.data(), gSnapshotRGBA.size());
    if (width) *width = gSnapshotW;
    if (height) *height = gSnapshotH;
    return true;
}

// MARK: - Text input

// PSDK keeps one typed string, and `Input.swap_states` clears it on
// every frame, so text that no screen reads is dropped by the next
// frame. There is no buffer to fill, so the answer is always yes. The
// gate the launcher puts on this call is for a core that queues text.
//
// The game's own request still goes out through the mode callback, so
// the launcher can put the keyboard up by itself. Only a PSDK build
// with `Input.open_virtual_keyboard` makes that request. An older
// build makes none, and the player opens the keyboard from the
// toolbar.
int psdk_isTextInputActive(void) { return 1; }

void psdk_pushTextInput(const char *utf8) {
    if (utf8) {
        psdk_inject_text(utf8);
    }
}

// MARK: - Alerts

// The launcher shows the alert and calls the signal when the person
// closes it. Nothing on this side waits, so the signals do nothing.
void psdk_presentErrorAndWait(const char *message) {
    if (gErrorMessage.fn) {
        reinterpret_cast<psdk_ErrorMessageCallback>(gErrorMessage.fn)(message,
                                                                     gErrorMessage.userdata);
    }
}

void psdk_presentInfoAndWait(const char *message) {
    if (gInfoMessage.fn) {
        reinterpret_cast<psdk_InfoMessageCallback>(gInfoMessage.fn)(message, gInfoMessage.userdata);
    }
}

void psdk_signalErrorDismissed(void) {}
void psdk_signalInfoDismissed(void) {}

// MARK: - What the launcher pushes

void psdk_setLauncherIdentity(const char *name) {
    std::lock_guard<std::mutex> guard(gLock);
    gLauncherIdentity = name ? name : "";
}

void psdk_setCABundlePath(const char *path) {
    std::lock_guard<std::mutex> guard(gLock);
    gCABundlePath = path ? path : "";
    // PSDK's Ruby reads this on its own openssl require.
    if (!gCABundlePath.empty()) {
        setenv("SSL_CERT_FILE", gCABundlePath.c_str(), 1);
    }
}

void psdk_setDebugLogPath(const char *path) {
    std::lock_guard<std::mutex> guard(gLock);
    gDebugLogPath = path ? path : "";
    if (gDebugLogPath.empty()) {
        return;
    }
    // A released PSDK game reports a failed boot on stderr and then ends
    // the process with `exit!`. A phone has no console, so without this
    // the report is lost and the app only disappears. The launcher
    // writes the file's header before this call, so append to it.
    //
    // dup2 on the descriptor, not freopen on the stream. Ruby writes to
    // descriptor 2 itself and never goes through C stdio, so only a
    // descriptor swap catches both the core's fprintf and the game's
    // `$stderr.puts`. Descriptor 1 goes too, because PSDK prints its
    // script-load progress there and that says how far the boot got.
    const int fd = open(gDebugLogPath.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        return;
    }
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    if (fd != STDOUT_FILENO && fd != STDERR_FILENO) {
        close(fd);
    }
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IOLBF, 0);
    fprintf(stderr, "[psdk] log is attached\n");
}

void psdk_setConfigOverlayJSON(const char *jsonUTF8) {
    std::lock_guard<std::mutex> guard(gLock);
    gConfigOverlayJSON = jsonUTF8 ? jsonUTF8 : "";
    gFixedAspectRatio.store(readFlagKey(gConfigOverlayJSON, "fixedAspectRatio", true));
    psdk_set_smooth(readFlagKey(gConfigOverlayJSON, "smoothScaling", false) ? 1 : 0);
}

void psdk_setCheatsEnabled(bool enabled) { gCheatsEnabled.store(enabled); }
bool psdk_getCheatsEnabled(void) { return gCheatsEnabled.load(); }

void psdk_setTouchMouseEnabled(bool enabled) { psdk_set_touch_enabled(enabled ? 1 : 0); }

void psdk_setGameControllerCaptureEnabled(bool enabled) {
    gControllerCaptureEnabled.store(enabled);
}

void psdk_setShowViewportBounds(bool enabled) { gShowViewportBounds.store(enabled); }
void psdk_setViewportBoundsColor(float, float, float, float) {}

void psdk_setFastForwardMultiplier(int multiplier) {
    gFastForwardMultiplier.store(multiplier);
    psdk_set_speed(multiplier);
}

int psdk_getFastForwardMultiplier(void) { return gFastForwardMultiplier.load(); }

void psdk_setHostViewportRegion(float x, float y, float w, float h, bool isPortrait) {
    gHostRegionX.store(x);
    gHostRegionY.store(y);
    gHostRegionW.store(w);
    gHostRegionH.store(h);
    gHostRegionPortrait.store(isPortrait);
    gHasHostRegion.store(true);
    placeOutputRegion();
}

void psdk_clearHostViewportRegion(void) {
    gHasHostRegion.store(false);
    placeOutputRegion();
}

void psdk_setSafeAreaInsets(float top, float bottom, float left, float right) {
    gSafeTop.store(top);
    gSafeBottom.store(bottom);
    gSafeLeft.store(left);
    gSafeRight.store(right);
    placeOutputRegion();
}

PsdkVerticalAlignment psdk_getVerticalAlignment(void) {
    return static_cast<PsdkVerticalAlignment>(gVerticalAlignment.load());
}

// A PSDK game keeps its saves in its own folder and loads its own
// fonts, so only the alignment reaches this core.
void psdk_applySessionConfig(const PsdkSessionConfig *config) {
    if (!config) {
        return;
    }
    gVerticalAlignment.store(config->verticalAlignment);
    placeOutputRegion();
}

// MARK: - What the launcher reads

void psdk_setSetting(const char *key, const char *value) {
    fprintf(stderr, "[psdk] unknown setting %s=%s\n", key ? key : "(null)", value ? value : "(null)");
}

// PSDK gives no title through any interface, so the launcher falls back
// to the library name.
const char *psdk_getGameTitle(void) { return ""; }
const char *psdk_getDetails(void) {
    static const std::string details = std::string("Ruby ") + psdk_ruby_version();
    return details.c_str();
}
double psdk_getAverageFPS(void) {
    const unsigned long long frames = gDrawnFrames.load();
    const double now = static_cast<double>(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9;
    const double then = gFpsMarkSeconds.exchange(now);
    const unsigned long long before = gFpsMarkFrames.exchange(frames);
    const double span = now - then;
    if (then <= 0.0 || span <= 0.0) {
        return 0.0;
    }
    return static_cast<double>(frames - before) / span;
}
int psdk_getTargetFPS(void) { return 60; }
