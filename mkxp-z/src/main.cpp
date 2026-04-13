/*
** main.cpp
**
** This file is part of mkxp.
**
** Copyright (C) 2013 - 2021 Amaryllis Kulla <ancurio@mapleshrine.eu>
**
** mkxp is free software: you can redistribute it and/or modify
** it under the terms of the GNU General Public License as published by
** the Free Software Foundation, either version 2 of the License, or
** (at your option) any later version.
**
** mkxp is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with mkxp.  If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef MKXPZ_BUILD_XCODE
#include "icon.png.xxd"
#endif

#include <alc.h>

#include <SDL.h>
#include <SDL_image.h>
#include <SDL_sound.h>
#include <SDL_ttf.h>

#include <assert.h>
#include <string.h>
#include <string>
#include <unistd.h>
#include <regex>

#if TARGET_OS_IPHONE
#include "ios_bridge.h"
#else
// Stubs so the LSP doesn't complain when TARGET_OS_IPHONE is undefined
static inline const char *mkxp_waitForGamePath(void) { return ""; }
static inline void mkxp_setEngineTerminated(void) {}
static inline void mkxp_resetBridgeState(void) {}
#endif

#include "binding.h"
#include "sharedstate.h"
#include "eventthread.h"
#include "display/graphics.h"
#include "util/debugwriter.h"
#include "util/exception.h"
#include "display/gl/gl-debug.h"
#include "display/gl/gl-fun.h"
#include "display/gl/gl-util.h"

#include "filesystem/filesystem.h"

#include "system/system.h"

#if defined(__WIN32__)
#include "resource.h"
#include <Winsock2.h>
#include "util/win-consoleutils.h"

// Try to work around buggy GL drivers that tend to be in Optimus laptops
// by forcing MKXP to use the dedicated card instead of the integrated one
#include <windows.h>
extern "C" {
__declspec(dllexport) DWORD NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}
#endif

#ifdef MKXPZ_STEAM
#include "steamshim_child.h"
#endif

#ifdef MKXPZ_BUILD_XCODE
#include <Availability.h>
#include <TargetConditionals.h>
#include "TouchBar.h"
#if !TARGET_OS_IPHONE && (!defined(__MAC_10_15) || __MAC_OS_X_VERSION_MAX_ALLOWED < __MAC_10_15)
#define MKXPZ_INIT_GL_LATER
#endif
#endif

#ifndef MKXPZ_INIT_GL_LATER
#define GLINIT_SHOWERROR(s) showInitError(s)
#else
#define GLINIT_SHOWERROR(s) rgssThreadError(threadData, s)
#endif

static void rgssThreadError(RGSSThreadData *rtData, const std::string &msg);
static void showInitError(const std::string &msg);

static inline const char *glGetStringInt(GLenum name) {
  return (const char *)gl.GetString(name);
}

static void printGLInfo() {
    const std::string renderer(glGetStringInt(GL_RENDERER));
    const std::string version(glGetStringInt(GL_VERSION));
    std::regex rgx("ANGLE \\((.+), ANGLE Metal Renderer: (.+), Version (.+)\\)");
        
    std::smatch matches;
    if (std::regex_search(renderer, matches, rgx)) {
        
        Debug() << "Backend           :" << "Metal";
        Debug() << "Metal Device      :" << matches[2] << "(" + matches[1].str() + ")";
        Debug() << "Renderer Version  :" << matches[3].str();
        
    std::smatch vmatches;
        if (std::regex_search(version, vmatches, std::regex("\\(ANGLE (.+) git hash: .+\\)"))) {
            Debug() << "ANGLE Version     :" << vmatches[1].str();
        }
        return;
    }
    
  Debug() << "Backend      :" << "OpenGL";
  Debug() << "GL Vendor    :" << glGetStringInt(GL_VENDOR);
  Debug() << "GL Renderer  :" << renderer;
  Debug() << "GL Version   :" << version;
  Debug() << "GLSL Version :" << glGetStringInt(GL_SHADING_LANGUAGE_VERSION);
  GLint maxTexSize = 0;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTexSize);
  Debug() << "Max Tex Size :" << maxTexSize;
}

static SDL_GLContext initGL(SDL_Window *win, Config &conf,
                            RGSSThreadData *threadData);

/* On iOS, the screen FBO is non-zero (SDL creates an FBO backed by
 * CAEAGLLayer). This ID is captured once during initGL() and reused
 * for all sessions, since the window and GL context persist.
 * Re-querying GL_FRAMEBUFFER_BINDING on subsequent sessions would
 * return 0 (because SharedState::finiInstance deleted all game FBOs
 * and GL reverts the binding to 0), which is wrong on iOS. */
#if TARGET_OS_IPHONE
static GLuint s_iosScreenFBO = 0;
#endif

#if TARGET_OS_IPHONE
/* Persistent RGSS thread for iOS.
 * Ruby 1.8's VM has internal state (parser, symbol table, thread-local
 * storage) bound to the thread that called ruby_init(). Creating a new
 * thread for each game session causes crashes because the VM's stack
 * boundaries and TLS references become stale.
 * Solution: keep the RGSS thread alive across sessions. The main thread
 * posts new RGSSThreadData via these shared variables. */
static SDL_sem *s_rgssSessionReady = nullptr;   // main → RGSS: "new session available"
static SDL_sem *s_rgssSessionDone  = nullptr;    // RGSS → main: "session finished"
static RGSSThreadData *s_nextRTData = nullptr;   // the data for the next session

int rgssThreadFun(void *userdata) {
  RGSSThreadData *threadData = static_cast<RGSSThreadData *>(userdata);

  SDL_GL_MakeCurrent(threadData->window, threadData->glContext);

  /* Set the screen framebuffer ID and reset the binding tracker. */
  FBO::screenFramebufferID = FBO::ID(s_iosScreenFBO);
  gl.BindFramebuffer(GL_FRAMEBUFFER, FBO::screenFramebufferID.gl);
  FBO::boundFramebufferID = FBO::screenFramebufferID;

  /* AL context — persistent, just activate on this thread. */
  ALCcontext *alcCtx = threadData->alcCtx;
  alcMakeContextCurrent(alcCtx);

  /* --- Session loop: runs on the SAME thread forever --- */
  while (true) {
    /* Re-set FBO state for this session (SharedState::finiInstance
     * may have unbound it). */
    FBO::screenFramebufferID = FBO::ID(s_iosScreenFBO);
    gl.BindFramebuffer(GL_FRAMEBUFFER, FBO::screenFramebufferID.gl);
    FBO::boundFramebufferID = FBO::screenFramebufferID;

    try {
      SharedState::initInstance(threadData);
    } catch (const Exception &exc) {
      rgssThreadError(threadData, exc.msg);
      break;
    }

    mkxp_setGameReady();

    /* Run game scripts */
    scriptBinding->execute();

    /* Detach disposables before destroying SharedState */
    shState->graphics().detachAllDisposables();

    threadData->rqTermAck.set();
    threadData->ethread->requestTerminate();

    SharedState::finiInstance();

    /* Signal main thread that session is done */
    SDL_SemPost(s_rgssSessionDone);

    /* Wait for the main thread to provide the next session's data.
     * This blocks until main calls SDL_SemPost(s_rgssSessionReady). */
    SDL_SemWait(s_rgssSessionReady);

    /* Pick up the new RGSSThreadData */
    threadData = s_nextRTData;
    if (!threadData)
      break; // null = quit
  }

  alcMakeContextCurrent(NULL);
  SDL_GL_MakeCurrent(threadData ? threadData->window : nullptr, NULL);

  return 0;
}

#else // !TARGET_OS_IPHONE — original single-session thread

int rgssThreadFun(void *userdata) {
  RGSSThreadData *threadData = static_cast<RGSSThreadData *>(userdata);

#ifdef MKXPZ_INIT_GL_LATER
  threadData->glContext =
      initGL(threadData->window, threadData->config, threadData);
  if (!threadData->glContext)
    return 0;
#else
  SDL_GL_MakeCurrent(threadData->window, threadData->glContext);
#endif

  /* Set the screen framebuffer ID and reset the binding tracker. */
  {
    /* On other platforms, query the real default framebuffer ID. */
    GLint defaultFBO = 0;
    gl.GetIntegerv(GL_FRAMEBUFFER_BINDING, &defaultFBO);
    FBO::screenFramebufferID = FBO::ID(static_cast<GLuint>(defaultFBO));
    gl.BindFramebuffer(GL_FRAMEBUFFER, FBO::screenFramebufferID.gl);
    FBO::boundFramebufferID = FBO::screenFramebufferID;
  }

  ALCcontext *alcCtx = threadData->alcCtx;

  if (!alcCtx) {
    alcCtx = alcCreateContext(threadData->alcDev, 0);
    if (!alcCtx) {
      rgssThreadError(threadData, "Error creating OpenAL context");
      return 0;
    }
  }

  alcMakeContextCurrent(alcCtx);

  try {
    SharedState::initInstance(threadData);
  } catch (const Exception &exc) {
    rgssThreadError(threadData, exc.msg);
    alcDestroyContext(alcCtx);
    return 0;
  }

  scriptBinding->execute();

  threadData->rqTermAck.set();
  threadData->ethread->requestTerminate();

  SharedState::finiInstance();

  alcDestroyContext(alcCtx);

  return 0;
}
#endif

static void printRgssVersion(int ver) {
  const char *const makers[] = {"", "XP", "VX", "VX Ace"};

  char buf[128];
  snprintf(buf, sizeof(buf), "RGSS version %d (RPG Maker %s)", ver,
           makers[ver]);

  Debug() << buf;
}

static void rgssThreadError(RGSSThreadData *rtData, const std::string &msg) {
  rtData->rgssErrorMsg = msg;
  rtData->ethread->requestTerminate();
  rtData->rqTermAck.set();
}

static void showInitError(const std::string &msg) {
  Debug() << msg;
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "mkxp-z", msg.c_str(), 0);
}

static void setupWindowIcon(const Config &conf, SDL_Window *win) {
  SDL_RWops *iconSrc;

  if (conf.iconPath.empty())
#ifndef MKXPZ_BUILD_XCODE
    iconSrc = SDL_RWFromConstMem(___assets_icon_png, ___assets_icon_png_len);
#else
    iconSrc = SDL_RWFromFile(mkxp_fs::getPathForAsset("icon", "png").c_str(), "rb");
#endif
  else
    iconSrc = SDL_RWFromFile(conf.iconPath.c_str(), "rb");

  SDL_Surface *iconImg = IMG_Load_RW(iconSrc, SDL_TRUE);

  if (iconImg) {
    SDL_SetWindowIcon(win, iconImg);
    SDL_FreeSurface(iconImg);
  }
}

int main(int argc, char *argv[]) {
  try {

#if TARGET_OS_IPHONE
    // --- FIRST LAUNCH: wait for Library UI before SDL_Init ---
    // SDL_Init creates an OpenGL window that would cover the Library UI,
    // so we wait for the user to pick a game first.
    char dataDir[512]{};
    const char *selectedPath = mkxp_waitForGamePath();
    if (selectedPath && selectedPath[0]) {
        strncpy(dataDir, selectedPath, sizeof(dataDir));
    }
#endif

    SDL_SetHint(SDL_HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, "0");
    SDL_SetHint(SDL_HINT_ACCELEROMETER_AS_JOYSTICK, "0");

#ifdef GLES2_HEADER
    SDL_SetHint(SDL_HINT_OPENGL_ES_DRIVER, "1");
#endif

    SDL_SetHint(SDL_HINT_IME_SHOW_UI, "1");

    /* initialize SDL first */
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_TIMER) < 0) {
      showInitError(std::string("Error initializing SDL: ") + SDL_GetError());
      return 0;
    }

    if (!EventThread::allocUserEvents()) {
      showInitError("Error allocating SDL user events");
      return 0;
    }

#ifndef WORKDIR_CURRENT
#if !TARGET_OS_IPHONE
    char dataDir[512]{};
#endif
#if defined(__linux__)
    char *tmp{};
    tmp = getenv("SRCDIR");
    if (tmp) {
      strncpy(dataDir, tmp, sizeof(dataDir));
    }
#endif
    if (!dataDir[0]) {
        strncpy(dataDir, mkxp_fs::getDefaultGameRoot().c_str(), sizeof(dataDir));
    }
    bool cwdOk = mkxp_fs::setCurrentDirectory(dataDir);
    (void)cwdOk;
#endif

    int imgFlags = IMG_INIT_PNG | IMG_INIT_JPG;
    if (IMG_Init(imgFlags) != imgFlags) {
      showInitError(std::string("Error initializing SDL_image: ") +
                    SDL_GetError());
      SDL_Quit();

#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif

      return 0;
    }

    if (TTF_Init() < 0) {
      showInitError(std::string("Error initializing SDL_ttf: ") +
                    SDL_GetError());
      IMG_Quit();
      SDL_Quit();

#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif

      return 0;
    }

    if (Sound_Init() == 0) {
      showInitError(std::string("Error initializing SDL_sound: ") +
                    Sound_GetError());
      TTF_Quit();
      IMG_Quit();
      SDL_Quit();

#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif

      return 0;
    }

#ifdef MKXPZ_STEAM
    if (!STEAMSHIM_init()) {
      showInitError("Failed to initialize Steamworks. The application cannot "
                    "continue launching.");
      SDL_Quit();
      return 0;
    }
#endif

#if defined(__WIN32__)
    WSAData wsadata = {0};
    if (WSAStartup(0x101, &wsadata) || wsadata.wVersion != 0x101) {
      char buf[200];
      snprintf(buf, sizeof(buf), "Error initializing winsock: %08X",
               WSAGetLastError());
      showInitError(std::string(buf));
    }
#endif

    // ================================================================
    // iOS: Create persistent window, GL context, and AL device ONCE.
    // These survive across game sessions to avoid GL context issues.
    // ================================================================
#if TARGET_OS_IPHONE
    // Set working directory for the first game (needed to read Config)
    mkxp_fs::setCurrentDirectory(dataDir);

    /* Read initial config to get window title/size (Config is re-read
     * per session, but we need one now for window creation). */
    Config initConf;
    initConf.read(argc, argv);

    Uint32 winFlags = SDL_WINDOW_OPENGL | SDL_WINDOW_INPUT_FOCUS | SDL_WINDOW_ALLOW_HIGHDPI;

#ifdef GLES2_HEADER
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
#endif

    /* Allow all orientations. Without this, SDL infers supported
     * orientations from the window w/h: a landscape-shaped game
     * (e.g. 640x480) would lock the window to landscape only,
     * preventing portrait gameplay. */
    SDL_SetHint(SDL_HINT_ORIENTATIONS,
                "Portrait LandscapeLeft LandscapeRight");

    SDL_Window *persistWin = SDL_CreateWindow(
        initConf.windowTitle.c_str(), SDL_WINDOWPOS_UNDEFINED,
        SDL_WINDOWPOS_UNDEFINED, initConf.defScreenW,
        initConf.defScreenH, winFlags);

    if (!persistWin) {
      showInitError(std::string("Error creating window: ") + SDL_GetError());
      return 0;
    }

    SDL_GLContext persistGLCtx = initGL(persistWin, initConf, 0);

    ALCdevice *persistAlcDev = alcOpenDevice(0);
    if (!persistAlcDev) {
      showInitError("Could not detect an available audio device.");
      SDL_GL_DeleteContext(persistGLCtx);
      SDL_DestroyWindow(persistWin);
      return 0;
    }

    ALCcontext *persistAlcCtx = alcCreateContext(persistAlcDev, 0);
    if (persistAlcCtx)
      alcMakeContextCurrent(persistAlcCtx);

    SDL_DisplayMode mode;
    SDL_GetDisplayMode(0, 0, &mode);

    // ================================================================
    // Game session loop — persistent RGSS thread
    // ================================================================
    s_rgssSessionReady = SDL_CreateSemaphore(0);
    s_rgssSessionDone  = SDL_CreateSemaphore(0);
    SDL_Thread *rgssThread = nullptr;
    bool firstSession = true;
    while (true) {
    // On subsequent sessions, wait for the library to provide a new game path
    if (!firstSession) {
        mkxp_setEngineTerminated();
        EventThread::resetAllInputStates();
        const char *nextPath = mkxp_waitForGamePath();
        if (nextPath && nextPath[0]) {
            strncpy(dataDir, nextPath, sizeof(dataDir));
        } else {
            break; // empty path = quit
        }
        // Reset bridge state AFTER copying the path, so the UI has had time
        // to observe mkxp_isEngineTerminated() during mkxp_waitForGamePath().
        mkxp_resetBridgeState();

        // Set working directory to the selected game
        mkxp_fs::setCurrentDirectory(dataDir);
    }
    firstSession = false;

    /* Read the game's config */
    Config conf;
    conf.read(argc, argv);

    if (conf.windowTitle.empty())
      conf.windowTitle = conf.game.title;

    assert(conf.rgssVersion >= 1 && conf.rgssVersion <= 3);
    printRgssVersion(conf.rgssVersion);

    /* Update the persistent window for this game session */
    SDL_SetWindowTitle(persistWin, conf.windowTitle.c_str());

    if (!mode.refresh_rate)
      conf.syncToRefreshrate = false;

    EventThread eventThread;

    RGSSThreadData rtData(&eventThread, argv[0], persistWin, persistAlcDev,
                          persistAlcCtx, mode.refresh_rate,
                          mkxp_sys::getScalingFactor(), conf, persistGLCtx);

    int winW, winH, drwW, drwH;
    SDL_GetWindowSize(persistWin, &winW, &winH);
    rtData.windowSizeMsg.post(Vec2i(winW, winH));

    SDL_GL_GetDrawableSize(persistWin, &drwW, &drwH);
    rtData.drawableSizeMsg.post(Vec2i(drwW, drwH));

    /* Load and post key bindings */
    rtData.bindingUpdateMsg.post(loadBindings(conf));

    /* Drain stale events (especially SDL_QUIT) left over from the
     * previous session so the event loop doesn't exit immediately. */
    SDL_FlushEvents(SDL_FIRSTEVENT, SDL_LASTEVENT);

    if (!rgssThread) {
        /* First session: create the persistent RGSS thread.
         * Use 16 MB stack for Ruby 1.8's GC stack scanning. */
        rgssThread = SDL_CreateThreadWithStackSize(rgssThreadFun, "rgss",
                                                   16 * 1024 * 1024, &rtData);
    } else {
        /* Subsequent sessions: signal the persistent RGSS thread
         * with the new session data. */
        s_nextRTData = &rtData;
        SDL_SemPost(s_rgssSessionReady);
    }

    /* Start event processing (blocks until game ends) */
    eventThread.process(rtData);

    /* Request RGSS thread to stop */
    rtData.rqTerm.set();

    /* Wait for RGSS thread to finish THIS session (not the thread itself).
     * The thread stays alive, waiting for the next session. */
    for (int i = 0; i < 1000; ++i) {
      if (rtData.rqTermAck) {
        Debug() << "RGSS thread ack'd request after" << i * 10 << "ms";
        break;
      }
      SDL_Delay(10);
    }

    if (rtData.rqTermAck) {
        /* Wait for the RGSS thread to finish cleanup (SharedState::finiInstance)
         * before we proceed. It will post s_rgssSessionDone then block on
         * s_rgssSessionReady. */
        SDL_SemWait(s_rgssSessionDone);
    } else {
#if TARGET_OS_IPHONE
      mkxp_setErrorMessage(
          std::string("The RGSS script seems to be stuck. "+conf.game.title+" will now force quit.").c_str());
#else
      SDL_ShowSimpleMessageBox(
          SDL_MESSAGEBOX_ERROR, conf.game.title.c_str(),
          std::string("The RGSS script seems to be stuck. "+conf.game.title+" will now force quit.").c_str(),
          persistWin);
#endif
    }

    if (!rtData.rgssErrorMsg.empty()) {
      Debug() << rtData.rgssErrorMsg;
#if TARGET_OS_IPHONE
      mkxp_setErrorMessage(rtData.rgssErrorMsg.c_str());
#else
      SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, conf.game.title.c_str(),
                               rtData.rgssErrorMsg.c_str(), persistWin);
#endif
    }

    /* Clean up any remaining events */
    eventThread.cleanup();

    /* Clear the framebuffer to black so the next session doesn't
     * briefly flash the last frame of the previous session.
     * NOTE: GL context is held by the RGSS thread (which is blocked
     * on s_rgssSessionReady). Temporarily claim it here. */
    SDL_GL_MakeCurrent(persistWin, persistGLCtx);
    gl.BindFramebuffer(GL_FRAMEBUFFER, s_iosScreenFBO);
    gl.ClearColor(0, 0, 0, 1);
    gl.Clear(GL_COLOR_BUFFER_BIT);
    SDL_GL_SwapWindow(persistWin);
    SDL_GL_MakeCurrent(persistWin, NULL);

    Debug() << "Game session ended.";

    continue;
    } // end while(true) game session loop

    /* Signal the RGSS thread to exit */
    s_nextRTData = nullptr;
    SDL_SemPost(s_rgssSessionReady);
    SDL_WaitThread(rgssThread, 0);
    SDL_DestroySemaphore(s_rgssSessionReady);
    SDL_DestroySemaphore(s_rgssSessionDone);

    /* Cleanup persistent resources (unreachable in normal flow,
     * but good form in case we ever break out of the loop) */
    if (persistGLCtx)
      SDL_GL_DeleteContext(persistGLCtx);
    alcMakeContextCurrent(NULL);
    if (persistAlcCtx)
      alcDestroyContext(persistAlcCtx);
    alcCloseDevice(persistAlcDev);
    SDL_DestroyWindow(persistWin);

#else // !TARGET_OS_IPHONE — original single-session flow

    // ================================================================
    // Non-iOS: single-pass flow (no session loop)
    // ================================================================

    /* now we load the config */
    Config conf;
    conf.read(argc, argv);

#if defined(__WIN32__)
    // Create a debug console in debug mode
    if (conf.winConsole) {
      if (setupWindowsConsole()) {
        reopenWindowsStreams();
      } else {
        char buf[200];
        snprintf(buf, sizeof(buf), "Error allocating console: %lu",
                GetLastError());
        showInitError(std::string(buf));
      }
    }
#endif

    if (conf.windowTitle.empty())
      conf.windowTitle = conf.game.title;

    assert(conf.rgssVersion >= 1 && conf.rgssVersion <= 3);
    printRgssVersion(conf.rgssVersion);

    SDL_Window *win;
    Uint32 winFlags = SDL_WINDOW_OPENGL | SDL_WINDOW_INPUT_FOCUS | SDL_WINDOW_ALLOW_HIGHDPI;

    if (conf.winResizable)
      winFlags |= SDL_WINDOW_RESIZABLE;
    if (conf.fullscreen)
      winFlags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    
#ifdef GLES2_HEADER
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);

    // LoadLibrary properly initializes EGL, it won't work otherwise.
    // Doesn't completely do it though, needs a small patch to SDL
#if defined(MKXPZ_BUILD_XCODE) && !TARGET_OS_IPHONE
    SDL_setenv("ANGLE_DEFAULT_PLATFORM", (conf.preferMetalRenderer) ? "metal" : "opengl", true);
    SDL_GL_LoadLibrary("@rpath/libEGL.dylib");
#endif
#endif
    
    win = SDL_CreateWindow(conf.windowTitle.c_str(), SDL_WINDOWPOS_UNDEFINED,
                           SDL_WINDOWPOS_UNDEFINED, conf.defScreenW,
                           conf.defScreenH, winFlags);

    if (!win) {
      showInitError(std::string("Error creating window: ") + SDL_GetError());
#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif
      return 0;
    }
    
#if defined(MKXPZ_BUILD_XCODE) && !TARGET_OS_IPHONE
    {
        std::string downloadsPath = "/Users/" + mkxp_sys::getUserName() + "/Downloads";
        
        if (mkxp_fs::getCurrentDirectory().find(downloadsPath) == 0) {
            showInitError(conf.game.title +
                          " cannot run from the Downloads directory.\n\n" +
                          "Please move the application to the Applications folder (or anywhere else) " +
                          "and try again.");
#ifdef MKXPZ_STEAM
            STEAMSHIM_deinit();
#endif
            return 0;
        }
    }
#endif
    
#if defined(MKXPZ_BUILD_XCODE)
#define DEBUG_FSELECT_MSG "Select the folder from which to load game files. This is the folder containing the game's INI."
#define DEBUG_FSELECT_PROMPT "Load Game"
    if (conf.manualFolderSelect) {
        std::string dataDirStr = mkxp_fs::selectPath(win, DEBUG_FSELECT_MSG, DEBUG_FSELECT_PROMPT);
        if (!dataDirStr.empty()) {
            conf.gameFolder = dataDirStr;
            mkxp_fs::setCurrentDirectory(dataDirStr.c_str());
            Debug() << "Current directory set to" << dataDirStr;
            conf.read(argc, argv);
            conf.readGameINI();
        }
    }
#endif

    /* OSX and Windows have their own native ways of
     * dealing with icons; don't interfere with them */
#ifdef __LINUX__
    setupWindowIcon(conf, win);
#else
    (void)setupWindowIcon;
#endif

    ALCdevice *alcDev = alcOpenDevice(0);

    if (!alcDev) {
      showInitError("Could not detect an available audio device.");
      SDL_DestroyWindow(win);
      TTF_Quit();
      IMG_Quit();
      SDL_Quit();

#ifdef MKXPZ_STEAM
      STEAMSHIM_deinit();
#endif
      return 0;
    }

    ALCcontext *alcCtx = alcCreateContext(alcDev, 0);
    if (alcCtx)
      alcMakeContextCurrent(alcCtx);

    SDL_DisplayMode mode;
    SDL_GetDisplayMode(0, 0, &mode);

    /* Can't sync to display refresh rate if its value is unknown */
    if (!mode.refresh_rate)
      conf.syncToRefreshrate = false;

    EventThread eventThread;

#ifndef MKXPZ_INIT_GL_LATER
    SDL_GLContext glCtx = initGL(win, conf, 0);
#else
    SDL_GLContext glCtx = NULL;
#endif

    RGSSThreadData rtData(&eventThread, argv[0], win, alcDev, alcCtx, mode.refresh_rate,
                          mkxp_sys::getScalingFactor(), conf, glCtx);

    int winW, winH, drwW, drwH;
    SDL_GetWindowSize(win, &winW, &winH);
    rtData.windowSizeMsg.post(Vec2i(winW, winH));
    
    SDL_GL_GetDrawableSize(win, &drwW, &drwH);
    rtData.drawableSizeMsg.post(Vec2i(drwW, drwH));

    /* Load and post key bindings */
    rtData.bindingUpdateMsg.post(loadBindings(conf));
    
#ifdef MKXPZ_BUILD_XCODE
    // Create Touch Bar
    initTouchBar(win, conf);
#endif

    /* Start RGSS thread */
    SDL_Thread *rgssThread = SDL_CreateThread(rgssThreadFun, "rgss", &rtData);

    /* Start event processing */
    eventThread.process(rtData);

    /* Request RGSS thread to stop */
    rtData.rqTerm.set();

    /* Wait for RGSS thread response */
    for (int i = 0; i < 1000; ++i) {
      /* We can stop waiting when the request was ack'd */
      if (rtData.rqTermAck) {
        Debug() << "RGSS thread ack'd request after" << i * 10 << "ms";
        break;
      }

      /* Give RGSS thread some time to respond */
      SDL_Delay(10);
    }

    /* If RGSS thread ack'd request, wait for it to shutdown,
     * otherwise abandon hope and just end the process as is. */
    if (rtData.rqTermAck)
      SDL_WaitThread(rgssThread, 0);
    else
      SDL_ShowSimpleMessageBox(
          SDL_MESSAGEBOX_ERROR, conf.game.title.c_str(),
          std::string("The RGSS script seems to be stuck. "+conf.game.title+" will now force quit.").c_str(),
          win);

    if (!rtData.rgssErrorMsg.empty()) {
      Debug() << rtData.rgssErrorMsg;
      SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, conf.game.title.c_str(),
                               rtData.rgssErrorMsg.c_str(), win);
    }

    if (rtData.glContext)
      SDL_GL_DeleteContext(rtData.glContext);

    /* Clean up any remaining events */
    eventThread.cleanup();

    Debug() << "Game session ended.";

    alcMakeContextCurrent(NULL);
    if (alcCtx)
      alcDestroyContext(alcCtx);
    alcCloseDevice(alcDev);
    SDL_DestroyWindow(win);

#endif // TARGET_OS_IPHONE

    Debug() << "Shutting down.";

#if defined(__WIN32__)
    if (wsadata.wVersion)
      WSACleanup();
#endif

#ifdef MKXPZ_STEAM
    STEAMSHIM_deinit();
#endif
    Sound_Quit();
    TTF_Quit();
    IMG_Quit();
    SDL_Quit();

    return 0;
  } catch (const Exception &exc) {
    Debug() << "FATAL uncaught Exception:" << exc.msg;
    return 1;
  } catch (const std::exception &e) {
    Debug() << "FATAL uncaught std::exception:" << e.what();
    return 1;
  } catch (...) {
    Debug() << "FATAL unknown exception caught";
    return 1;
  }
}

static SDL_GLContext initGL(SDL_Window *win, Config &conf,
                            RGSSThreadData *threadData) {
  SDL_GLContext glCtx{};

  /* Setup GL context. Must be done in main thread since macOS 10.15 */
  SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    
  if (conf.debugMode)
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, SDL_GL_CONTEXT_DEBUG_FLAG);

  glCtx = SDL_GL_CreateContext(win);

  if (!glCtx) {
    GLINIT_SHOWERROR(std::string("Could not create OpenGL context: ") + SDL_GetError());
    return 0;
  }

#if TARGET_OS_IPHONE
  /* Capture the screen FBO right after context creation, while SDL's
   * CAEAGLLayer-backed FBO is still bound. This value persists for the
   * lifetime of the window and is reused by all game sessions. */
  {
    GLint fbo = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    s_iosScreenFBO = static_cast<GLuint>(fbo);
  }
#endif

  try {
    initGLFunctions();
  } catch (const Exception &exc) {
    GLINIT_SHOWERROR(exc.msg);
    SDL_GL_DeleteContext(glCtx);

    return 0;
  }

  if (!conf.enableBlitting)
    gl.BlitFramebuffer = 0;

  gl.ClearColor(0, 0, 0, 1);
  gl.Clear(GL_COLOR_BUFFER_BIT);
  SDL_GL_SwapWindow(win);

  printGLInfo();

  bool vsync = conf.vsync || conf.syncToRefreshrate;
  SDL_GL_SetSwapInterval(vsync ? 1 : 0);

  // GLDebugLogger dLogger;
  return glCtx;
}
