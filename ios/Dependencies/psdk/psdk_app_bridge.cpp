// The launcher interface for the PSDK core.
//
// A launcher opens one core and calls it through the psdk_* names
// psdk_app_bridge.h declares. This core answers them on top of
// LiteRGSS2, LiteCGSS, SFML and Ruby 3.0, and takes nothing from
// another engine.
//
// Five things here do real work: the game thread, the key translator,
// the game window, the frame signal and the picture placement. The rest
// stores what the launcher pushes or gives a fixed answer. Every
// function that gives less than a full answer says so where it is.

#include "psdk_app_bridge.h"
#include "psdk_core.h"

#include <SFML/System/String.hpp>
#include <SFML/Window/Keyboard.hpp>

#include <algorithm>
#include <atomic>
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

// WindowImplUIKit.mm records the UIWindow it makes.
extern "C" void *sfml_ios_game_window();

// The three SFML names this core uses to place the picture.
// sfml_set_output_region takes fractions of the window with the origin at
// the top left, and 0, 0, 1, 1 gives the whole window back.
// sfml_window_pixel_size gives pixels: it multiplies -[UIView frame],
// which UIKit reports in points, by the backing scale.
// sfml_ios_backing_scale is that number, and it is the screen scale.
// The launcher speaks points, so every value it sends or reads crosses
// this scale.
extern "C" void sfml_set_output_region(float x, float y, float w, float h);
extern "C" void sfml_window_pixel_size(unsigned int *width, unsigned int *height);
extern "C" float sfml_ios_backing_scale();

// The text road. A game asks for the keyboard through
// sf::Keyboard::setVirtualKeyboardVisible, which SFML reports through
// the callback below, and it reads what the player typed from
// sf::Event::TextEntered, which sfml_ios_inject_character makes.
extern "C" void sfml_ios_inject_character(unsigned int unicode);
extern "C" void sfml_ios_set_virtual_keyboard_callback(void (*callback)(int, void *), void *userdata);

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

// SFML carries the game's keyboard request out through a plain C
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
std::atomic<bool> gSmoothScaling{false};
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
// Where the picture landed, in window pixels. The engine needs it to turn
// a touch on the screen into a point inside the game.
std::atomic<int> gPictureX{0};
std::atomic<int> gPictureY{0};
std::atomic<int> gPictureW{0};
std::atomic<int> gPictureH{0};

std::atomic<bool> gGameReady{false};
std::atomic<bool> gEngineTerminatedFlag{false};
std::atomic<bool> gExitedCleanly{false};
std::atomic<bool> gPausedFlag{false};
std::atomic<bool> gCheatsEnabled{false};
std::atomic<bool> gTouchMouseEnabled{false};
std::atomic<bool> gShowViewportBounds{false};
std::atomic<bool> gControllerCaptureEnabled{false};
std::atomic<bool> gUseInGameKeyboard{false};
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
// PsdkCore.framework and ships no PSDK file of its own. dladdr on a
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

// SDL puts a scancode at its USB HID usage, SFML counts from zero in its
// own order, so the two spaces share no number. Both sides are named
// here, never a literal.
int toSfmlScancode(int sdlScancode) {
    switch (sdlScancode) {
        case PSDK_SCANCODE_A: return sf::Keyboard::Scan::A;
        case PSDK_SCANCODE_B: return sf::Keyboard::Scan::B;
        case PSDK_SCANCODE_C: return sf::Keyboard::Scan::C;
        case PSDK_SCANCODE_D: return sf::Keyboard::Scan::D;
        case PSDK_SCANCODE_E: return sf::Keyboard::Scan::E;
        case PSDK_SCANCODE_F: return sf::Keyboard::Scan::F;
        case PSDK_SCANCODE_G: return sf::Keyboard::Scan::G;
        case PSDK_SCANCODE_H: return sf::Keyboard::Scan::H;
        case PSDK_SCANCODE_I: return sf::Keyboard::Scan::I;
        case PSDK_SCANCODE_J: return sf::Keyboard::Scan::J;
        case PSDK_SCANCODE_K: return sf::Keyboard::Scan::K;
        case PSDK_SCANCODE_L: return sf::Keyboard::Scan::L;
        case PSDK_SCANCODE_M: return sf::Keyboard::Scan::M;
        case PSDK_SCANCODE_N: return sf::Keyboard::Scan::N;
        case PSDK_SCANCODE_O: return sf::Keyboard::Scan::O;
        case PSDK_SCANCODE_P: return sf::Keyboard::Scan::P;
        case PSDK_SCANCODE_Q: return sf::Keyboard::Scan::Q;
        case PSDK_SCANCODE_R: return sf::Keyboard::Scan::R;
        case PSDK_SCANCODE_S: return sf::Keyboard::Scan::S;
        case PSDK_SCANCODE_T: return sf::Keyboard::Scan::T;
        case PSDK_SCANCODE_U: return sf::Keyboard::Scan::U;
        case PSDK_SCANCODE_V: return sf::Keyboard::Scan::V;
        case PSDK_SCANCODE_W: return sf::Keyboard::Scan::W;
        case PSDK_SCANCODE_X: return sf::Keyboard::Scan::X;
        case PSDK_SCANCODE_Y: return sf::Keyboard::Scan::Y;
        case PSDK_SCANCODE_Z: return sf::Keyboard::Scan::Z;
        case PSDK_SCANCODE_1: return sf::Keyboard::Scan::Num1;
        case PSDK_SCANCODE_2: return sf::Keyboard::Scan::Num2;
        case PSDK_SCANCODE_3: return sf::Keyboard::Scan::Num3;
        case PSDK_SCANCODE_4: return sf::Keyboard::Scan::Num4;
        case PSDK_SCANCODE_5: return sf::Keyboard::Scan::Num5;
        case PSDK_SCANCODE_6: return sf::Keyboard::Scan::Num6;
        case PSDK_SCANCODE_7: return sf::Keyboard::Scan::Num7;
        case PSDK_SCANCODE_8: return sf::Keyboard::Scan::Num8;
        case PSDK_SCANCODE_9: return sf::Keyboard::Scan::Num9;
        case PSDK_SCANCODE_0: return sf::Keyboard::Scan::Num0;
        case PSDK_SCANCODE_RETURN: return sf::Keyboard::Scan::Enter;
        case PSDK_SCANCODE_ESCAPE: return sf::Keyboard::Scan::Escape;
        case PSDK_SCANCODE_BACKSPACE: return sf::Keyboard::Scan::Backspace;
        case PSDK_SCANCODE_TAB: return sf::Keyboard::Scan::Tab;
        case PSDK_SCANCODE_SPACE: return sf::Keyboard::Scan::Space;
        case PSDK_SCANCODE_MINUS: return sf::Keyboard::Scan::Hyphen;
        case PSDK_SCANCODE_EQUALS: return sf::Keyboard::Scan::Equal;
        case PSDK_SCANCODE_LEFTBRACKET: return sf::Keyboard::Scan::LBracket;
        case PSDK_SCANCODE_RIGHTBRACKET: return sf::Keyboard::Scan::RBracket;
        case PSDK_SCANCODE_BACKSLASH: return sf::Keyboard::Scan::Backslash;
        case PSDK_SCANCODE_SEMICOLON: return sf::Keyboard::Scan::Semicolon;
        case PSDK_SCANCODE_APOSTROPHE: return sf::Keyboard::Scan::Apostrophe;
        case PSDK_SCANCODE_GRAVE: return sf::Keyboard::Scan::Grave;
        case PSDK_SCANCODE_COMMA: return sf::Keyboard::Scan::Comma;
        case PSDK_SCANCODE_PERIOD: return sf::Keyboard::Scan::Period;
        case PSDK_SCANCODE_SLASH: return sf::Keyboard::Scan::Slash;
        case PSDK_SCANCODE_F1: return sf::Keyboard::Scan::F1;
        case PSDK_SCANCODE_F2: return sf::Keyboard::Scan::F2;
        case PSDK_SCANCODE_F3: return sf::Keyboard::Scan::F3;
        case PSDK_SCANCODE_F4: return sf::Keyboard::Scan::F4;
        case PSDK_SCANCODE_F5: return sf::Keyboard::Scan::F5;
        case PSDK_SCANCODE_F6: return sf::Keyboard::Scan::F6;
        case PSDK_SCANCODE_F7: return sf::Keyboard::Scan::F7;
        case PSDK_SCANCODE_F8: return sf::Keyboard::Scan::F8;
        case PSDK_SCANCODE_F9: return sf::Keyboard::Scan::F9;
        case PSDK_SCANCODE_F10: return sf::Keyboard::Scan::F10;
        case PSDK_SCANCODE_F11: return sf::Keyboard::Scan::F11;
        case PSDK_SCANCODE_F12: return sf::Keyboard::Scan::F12;
        case PSDK_SCANCODE_RIGHT: return sf::Keyboard::Scan::Right;
        case PSDK_SCANCODE_LEFT: return sf::Keyboard::Scan::Left;
        case PSDK_SCANCODE_DOWN: return sf::Keyboard::Scan::Down;
        case PSDK_SCANCODE_UP: return sf::Keyboard::Scan::Up;
        case PSDK_SCANCODE_LCTRL: return sf::Keyboard::Scan::LControl;
        case PSDK_SCANCODE_LSHIFT: return sf::Keyboard::Scan::LShift;
        case PSDK_SCANCODE_LALT: return sf::Keyboard::Scan::LAlt;
        case PSDK_SCANCODE_HOME: return sf::Keyboard::Scan::Home;
        default: return sf::Keyboard::Scan::Unknown;
    }
}

void *runGame(void *) {
    const std::string bundle = ownBundlePath();
    const std::string support = bundle + "/PsdkSupport";
    const std::string prelude = bundle + "/runtime_prelude.rb";
    const char *path = psdk_waitForGamePath();

    int result = psdk_run(gArgc.load(), gArgv.load(), path, support.c_str(), prelude.c_str());
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

// SFML answers 0 until it makes the window. A scale of 0 would divide
// the game rect by zero, so the first placement reads 1.
float backingScale() {
    const float scale = sfml_ios_backing_scale();
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
    sfml_window_pixel_size(&windowW, &windowH);
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

    sfml_set_output_region(x, y, w, h);

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

} // namespace

// The four hooks below answer LiteRGSS2 and the SFML fork, which declare
// them weak. They are not part of the launcher interface, so the
// framework keeps them to itself and exports none of them.

// Zero until the first placement, which needs both a window and the
// game's resolution.
extern "C" int psdk_picture_rect_pixels(int *x, int *y, int *width, int *height) {
    const int w = gPictureW.load();
    const int h = gPictureH.load();
    if (w <= 0 || h <= 0) {
        return 0;
    }
    *x = gPictureX.load();
    *y = gPictureY.load();
    *width = w;
    *height = h;
    return 1;
}

extern "C" int psdk_touch_mouse_enabled(void) { return gTouchMouseEnabled.load() ? 1 : 0; }

extern "C" int psdk_smooth_scaling_enabled(void) { return gSmoothScaling.load() ? 1 : 0; }

extern "C" int psdk_fast_forward_multiplier(void) { return gFastForwardMultiplier.load(); }

// LiteRGSS2 calls this with the resolution the game asked for, from
// DisplayWindow.new and from resize_screen.
extern "C" void psdk_game_resolution(long width, long height) {
    gGameWidth.store(static_cast<int>(width));
    gGameHeight.store(static_cast<int>(height));
    placeOutputRegion();
}

// SFML calls this from Window::display on every frame it swaps.
extern "C" void psdk_frame_rendered() {
    // The game reports its resolution from DisplayWindow.new, which runs
    // before SFML makes the window, so that first placement has no
    // window to measure and does nothing. A drawn frame proves the
    // window exists. The size also changes on every rotation, so the
    // check reads the size itself instead of a "first frame" flag.
    unsigned int windowW = 0;
    unsigned int windowH = 0;
    sfml_window_pixel_size(&windowW, &windowH);
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
                windowW, windowH, sfml_ios_backing_scale());
    }
    if (gFrameRendered.fn) {
        reinterpret_cast<psdk_FrameRenderedCallback>(gFrameRendered.fn)(gFrameRendered.userdata);
    }
}

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

void psdk_injectKeyEvent(int scancode, int pressed) {
    int sfScan = toSfmlScancode(scancode);
    if (sfScan == sf::Keyboard::Scan::Unknown) {
        return;
    }
    psdk_inject_scancode(sfScan, pressed);

    // PSDK's name screen reads Return and Backspace as text, not as
    // keys: `update_name` confirms on code point 13 and deletes on 8.
    // On a desktop, SFML sends a text event with those code points
    // next to the key event. The iOS backend sends no text of its own,
    // so the two keys get theirs here. Escape gets none, because the
    // name screen would eat it and the player could not leave.
    if (pressed) {
        if (scancode == PSDK_SCANCODE_RETURN) {
            sfml_ios_inject_character('\r');
        } else if (scancode == PSDK_SCANCODE_BACKSPACE) {
            sfml_ios_inject_character('\b');
        }
    }
}

// MARK: - The window

void *psdk_getSDLUIKitWindow(void) { return sfml_ios_game_window(); }

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
    sfml_ios_set_virtual_keyboard_callback(cb ? forwardTextInputMode : nullptr, nullptr);
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
}

// MARK: - Pause

// PSDK has no pause interface. The game keeps running behind the pause
// menu, and the menu still opens, because the launcher needs the
// callback to open it.
//
// ponytail: the real stop is LiteCGSS's game loop, which Graphics.update
// drives. Add it when the menu has to freeze the game.
void psdk_requestPause(void) {
    gPausedFlag.store(true);
    if (gPaused.fn) {
        reinterpret_cast<psdk_PausedCallback>(gPaused.fn)(gPaused.userdata);
    }
}

void psdk_requestResume(void) {
    gPausedFlag.store(false);
    if (gResumed.fn) {
        reinterpret_cast<psdk_ResumedCallback>(gResumed.fn)(gResumed.userdata);
    }
}

bool psdk_isPaused(void) { return gPausedFlag.load(); }

// MARK: - Snapshots

// MkxpCore reads its last frame out of the GL buffer. This core does
// not, so the pause menu shows its own background instead of the frame.
//
// ponytail: LiteCGSS keeps a Snapshot member on DisplayWindow. Read that
// when the menu needs the frame behind it.
bool psdk_getSnapshotSize(int *width, int *height) {
    if (width) *width = 0;
    if (height) *height = 0;
    return false;
}

bool psdk_copySnapshotRGBA(unsigned char *, int, int *, int *) { return false; }

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

// The launcher sends what the player typed as UTF-8, and an SFML text
// event carries one code point, so the string goes out one code point
// at a time.
void psdk_pushTextInput(const char *utf8) {
    if (!utf8 || !utf8[0]) {
        return;
    }
    const sf::String text = sf::String::fromUtf8(utf8, utf8 + std::strlen(utf8));
    for (const auto character : text) {
        sfml_ios_inject_character(character);
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
    gSmoothScaling.store(readFlagKey(gConfigOverlayJSON, "smoothScaling", false));
}

void psdk_setCheatsEnabled(bool enabled) { gCheatsEnabled.store(enabled); }
bool psdk_getCheatsEnabled(void) { return gCheatsEnabled.load(); }

void psdk_setTouchMouseEnabled(bool enabled) { gTouchMouseEnabled.store(enabled); }

void psdk_setGameControllerCaptureEnabled(bool enabled) {
    gControllerCaptureEnabled.store(enabled);
}

void psdk_setUseInGameKeyboard(bool enabled) { gUseInGameKeyboard.store(enabled); }

void psdk_setShowViewportBounds(bool enabled) { gShowViewportBounds.store(enabled); }
void psdk_setViewportBoundsColor(float, float, float, float) {}

void psdk_setFastForwardMultiplier(int multiplier) {
    gFastForwardMultiplier.store(multiplier);
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

// RGSS is RPG Maker's runtime. A PSDK game runs on LiteRGSS, so these
// answer "no RGSS version" and the mask says this core runs none. The
// launcher reads the mask from the framework's Info.plist before it
// opens any core, so an RPG Maker import never lands here.
void psdk_setActiveRubyVersion(PsdkRubyVersion) {}
void psdk_setSyntaxTransformMode(PsdkSyntaxTransformMode) {}
PsdkSyntaxTransformMode psdk_getSyntaxTransformMode(void) { return PSDK_SYNTAX_TRANSFORM_UNSET; }
int psdk_getRGSSVersion(void) { return 0; }
int psdk_getSupportedRGSSVersionMask(void) { return 0; }
PsdkVerticalAlignment psdk_getVerticalAlignment(void) {
    return static_cast<PsdkVerticalAlignment>(gVerticalAlignment.load());
}

// Two fields reach this core. A PSDK game keeps its saves in its own
// folder and loads its own fonts, so managedConfigDir, userDataDirectory
// and sharedFontsDirectory name nothing here. rubyVersion,
// syntaxTransformMode, postloadEnabled and joiplayCompat are all mkxp-z
// settings.
void psdk_applySessionConfig(const PsdkSessionConfig *config) {
    if (!config) {
        return;
    }
    psdk_setUseInGameKeyboard(config->useInGameKeyboard);
    gVerticalAlignment.store(config->verticalAlignment);
    placeOutputRegion();
}

// MARK: - What the launcher reads

// The launcher shows these on its debug overlay. PSDK gives no title
// through any interface, so the launcher falls back to the library name.
// "unknown" is what the interface says a core returns for a renderer
// string it cannot read, and the overlay hides a row that says it.
const char *psdk_getGameTitle(void) { return ""; }
const char *psdk_getRubyVersion(void) { return "3.0"; }
const char *psdk_getANGLEVersion(void) { return "unknown"; }
const char *psdk_getMetalDeviceName(void) { return "unknown"; }
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
