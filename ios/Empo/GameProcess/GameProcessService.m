#import "GameProcessService.h"

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <crt_externs.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#import "AppMemory.h"
#import "AudioSession.h"
#import "EmpoCore.h"
#import "EmpoGameProcessProtocol.h"
#include "GameCore.h"

static NSXPCConnection *gConnection;
static BOOL gCoreOpen;

static id<EmpoGameProcessHost> host(void) {
    return gConnection.remoteObjectProxy;
}

static NSString *text(const char *utf8) {
    return (utf8 != NULL ? [NSString stringWithUTF8String:utf8] : nil) ?: @"";
}

static uint64_t memoryFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return info.phys_footprint;
}

// The app called every gamecore_* function on its main thread when the
// core ran in the app. The process keeps that, in the order the calls
// came. A call that comes after a core failed to open does nothing.
static void onMain(dispatch_block_t call) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCoreOpen) {
            call();
        }
    });
}

// One "0x..." line, with no call that a signal handler cannot make.
static void writeHex(uintptr_t value) {
    char line[2 + 2 * sizeof(value) + 1];
    size_t end = sizeof(line);
    line[--end] = '\n';
    do {
        line[--end] = "0123456789abcdef"[value & 0xf];
        value >>= 4;
    } while (value != 0);
    line[--end] = 'x';
    line[--end] = '0';
    write(STDERR_FILENO, line + end, sizeof(line) - end);
}

// Writes the signal and the stack of a crash to stderr, which is the
// session log by then, and lets the crash go on. Ruby puts its own
// handler on SIGSEGV and SIGBUS when it starts, and its report is
// better.
static void onCrashSignal(int signal) {
    static const char prefix[] = "[game-process] crashed with signal ";
    write(STDERR_FILENO, prefix, sizeof(prefix) - 1);
    const char *name = "?";
    switch (signal) {
    case SIGABRT: name = "SIGABRT"; break;
    case SIGBUS: name = "SIGBUS"; break;
    case SIGFPE: name = "SIGFPE"; break;
    case SIGILL: name = "SIGILL"; break;
    case SIGSEGV: name = "SIGSEGV"; break;
    case SIGTRAP: name = "SIGTRAP"; break;
    }
    write(STDERR_FILENO, name, strlen(name));
    write(STDERR_FILENO, "\n", 1);
    // backtrace only walks the frame pointers. backtrace_symbols_fd
    // calls dladdr, which takes the dyld lock, and the crash can hold
    // that lock. The image list that captureOutput writes turns these
    // addresses into symbols.
    void *frames[128];
    int count = backtrace(frames, 128);
    for (int i = 0; i < count; i++) {
        writeHex((uintptr_t)frames[i]);
    }
    struct sigaction fallback = {.sa_handler = SIG_DFL};
    sigaction(signal, &fallback, NULL);
    raise(signal);
}

// Sends stdout and stderr to the session log, which the engine writes
// too, so a report holds what the core printed before a crash.
static void captureOutput(const char *logPath) {
    int log = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (log < 0) {
        NSLog(@"[game-process] cannot open %s: %s", logPath, strerror(errno));
        return;
    }
    dup2(log, STDOUT_FILENO);
    dup2(log, STDERR_FILENO);
    close(log);
    setvbuf(stdout, NULL, _IOLBF, 0);

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, ".app/") != NULL) {
            fprintf(stderr, "[game-process] image %p %s\n", (void *)_dyld_get_image_header(i), name);
        }
    }

    static const int crashSignals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP};
    for (size_t i = 0; i < sizeof(crashSignals) / sizeof(crashSignals[0]); i++) {
        struct sigaction action = {.sa_handler = onCrashSignal};
        sigaction(crashSignals[i], &action, NULL);
    }
}

static void onEngineTerminated(void *userdata) {
    [host() engineTerminatedCleanly:gamecore_didEngineExitCleanly() != 0 hung:gamecore_isEngineHung() != 0];
}

static void onGameRectChanged(float x, float y, float width, float height, void *userdata) {
    [host() gameRectChangedX:x y:y width:width height:height];
}

static void onTextInputMode(int active, void *userdata) {
    [host() textInputModeChanged:active != 0];
}

static void onErrorMessage(const char *message, void *userdata) {
    [host() errorMessage:text(message)];
}

static void onInfoMessage(const char *message, void *userdata) {
    [host() infoMessage:text(message)];
}

// The core waits in this callback until the app resumes it, so the
// snapshot it copies is the paused frame.
static void onPaused(void *userdata) {
    int width = 0;
    int height = 0;
    NSMutableData *rgba = nil;
    if (gamecore_getSnapshotSize(&width, &height) && width > 0 && height > 0) {
        rgba = [NSMutableData dataWithLength:(NSUInteger)width * (NSUInteger)height * 4];
        if (!gamecore_copySnapshotRGBA(rgba.mutableBytes, (int)rgba.length, &width, &height)) {
            rgba = nil;
        }
    }
    [host() pausedWithSnapshot:rgba width:width height:height];
}

static void onResumed(void *userdata) {
    [host() resumed];
}

// The core's SDL takes the one handler slot when it starts, and again
// when a keyboard connects. The app maps the keys, so this takes the
// slot back after each of those.
static void claimKeyboard(void) {
    GCKeyboard.coalescedKeyboard.keyboardInput.keyChangedHandler =
        ^(GCKeyboardInput *input, GCControllerButtonInput *key, GCKeyCode keyCode, BOOL pressed) {
          [host() keyChanged:keyCode pressed:pressed];
        };
}

static void onFrameRendered(void *userdata) {
    static dispatch_once_t claimed;
    dispatch_once(&claimed, ^{
      dispatch_async(dispatch_get_main_queue(), ^{ claimKeyboard(); });
    });
    [host() frameRendered];
}

static BOOL gSceneActive;
static BOOL gRunPending;

// A core may hold the main thread until the game ends, so it runs from
// a run loop callout and not from a block on the main queue
// (GameCore.h). Its caller runs on the main queue, after every call
// that came before runApp.
static void runCore(void) {
    gRunPending = NO;
    CFRunLoopRef mainLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
      gamecore_run_app(*_NSGetArgc(), *_NSGetArgv());
    });
    CFRunLoopWakeUp(mainLoop);
}

@interface EmpoGameProcessService : NSObject <EmpoGameProcess>
@end

@implementation EmpoGameProcessService

// The app can send runApp before ExtensionKit connects the scene of this
// process. A window that the core makes before that has no scene, and
// UIKit never shows it, so the core waits for the scene.
+ (void)load {
    [NSNotificationCenter.defaultCenter
        addObserverForName:UISceneDidActivateNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
                  if (gSceneActive || ![note.object isKindOfClass:UIWindowScene.class]) {
                      return;
                  }
                  gSceneActive = YES;
                  if (gRunPending) {
                      runCore();
                  }
                }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
                                                  claimKeyboard();
                                                }];
}

- (void)useMemory:(xpc_object_t)memory {
    EmpoUseAppMemory(memory);
}

- (void)openCore:(NSString *)framework reply:(void (^)(NSString *_Nullable))reply {
    // The extension sits in Empo.app/Extensions, and the cores in
    // Empo.app/Frameworks.
    NSURL *app = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSURL *binary = [[app URLByAppendingPathComponent:[NSString stringWithFormat:@"Frameworks/%@.framework", framework]]
        URLByAppendingPathComponent:framework];
    dispatch_async(dispatch_get_main_queue(), ^{
        EmpoConfigureAudioSession();
        if (!EmpoCoreOpen(binary.fileSystemRepresentation)) {
            reply([NSString stringWithFormat:@"cannot open %@", binary.path]);
            return;
        }
        gCoreOpen = YES;
        gamecore_setEngineTerminatedCallback(onEngineTerminated, NULL);
        gamecore_setGameRectChangedCallback(onGameRectChanged, NULL);
        gamecore_setTextInputModeCallback(onTextInputMode, NULL);
        gamecore_setErrorMessageCallback(onErrorMessage, NULL);
        gamecore_setInfoMessageCallback(onInfoMessage, NULL);
        gamecore_setPausedCallback(onPaused, NULL);
        gamecore_setResumedCallback(onResumed, NULL);
        gamecore_setFrameRenderedCallback(onFrameRendered, NULL);
        NSLog(@"[game-process] %d opened %@", getpid(), framework);
        reply(nil);
    });
}

- (void)setGamePath:(NSString *)path {
    onMain(^{
      gamecore_setGamePath(path.fileSystemRepresentation);
    });
}

- (void)runApp {
    onMain(^{
      if (gSceneActive) {
          runCore();
      } else {
          gRunPending = YES;
      }
    });
}

- (void)injectKeyEvent:(int)scancode pressed:(int)pressed {
    onMain(^{
      gamecore_injectKeyEvent(scancode, pressed);
    });
}

- (void)setLauncherIdentity:(NSString *)name {
    onMain(^{
      gamecore_setLauncherIdentity(name.UTF8String);
    });
}

- (void)setCABundlePath:(NSString *)path {
    onMain(^{
      gamecore_setCABundlePath(path.fileSystemRepresentation);
    });
}

- (void)pushTextInput:(NSString *)text {
    onMain(^{
      gamecore_pushTextInput(text.UTF8String);
    });
}

- (void)setSafeAreaInsetsTop:(float)top bottom:(float)bottom left:(float)left right:(float)right {
    onMain(^{
      gamecore_setSafeAreaInsets(top, bottom, left, right);
    });
}

- (void)setHostViewportRegionX:(float)x y:(float)y width:(float)width height:(float)height portrait:(BOOL)portrait {
    onMain(^{
      gamecore_setHostViewportRegion(x, y, width, height, portrait);
    });
}

- (void)clearHostViewportRegion {
    onMain(^{
      gamecore_clearHostViewportRegion();
    });
}

- (void)applySessionConfigUserData:(NSString *)userDataDirectory
                             fonts:(NSString *)sharedFontsDirectory
                 verticalAlignment:(int)verticalAlignment {
    onMain(^{
      GameCoreSessionConfig config = {
          .userDataDirectory = userDataDirectory.fileSystemRepresentation,
          .sharedFontsDirectory = sharedFontsDirectory.fileSystemRepresentation,
          .verticalAlignment = (GameCoreVerticalAlignment)verticalAlignment,
      };
      gamecore_applySessionConfig(&config);
    });
}

- (void)setSetting:(NSString *)key value:(NSString *)value {
    onMain(^{
      gamecore_setSetting(key.UTF8String, value.UTF8String);
    });
}

- (void)setShowViewportBounds:(BOOL)enabled {
    onMain(^{
      gamecore_setShowViewportBounds(enabled);
    });
}

- (void)setViewportBoundsColorRed:(float)red green:(float)green blue:(float)blue alpha:(float)alpha {
    onMain(^{
      gamecore_setViewportBoundsColor(red, green, blue, alpha);
    });
}

- (void)setCheatsEnabled:(BOOL)enabled {
    onMain(^{
      gamecore_setCheatsEnabled(enabled);
    });
}

- (void)setGameControllerCaptureEnabled:(BOOL)enabled {
    onMain(^{
      gamecore_setGameControllerCaptureEnabled(enabled);
    });
}

- (void)setTouchMouseEnabled:(BOOL)enabled {
    onMain(^{
      gamecore_setTouchMouseEnabled(enabled);
    });
}

- (void)signalErrorDismissed {
    onMain(^{
      gamecore_signalErrorDismissed();
    });
}

- (void)signalInfoDismissed {
    onMain(^{
      gamecore_signalInfoDismissed();
    });
}

- (void)requestPause {
    onMain(^{
      gamecore_requestPause();
    });
}

- (void)requestResume {
    onMain(^{
      gamecore_requestResume();
    });
}

- (void)setFastForwardMultiplier:(int)multiplier {
    onMain(^{
      gamecore_setFastForwardMultiplier(multiplier);
    });
}

- (void)resetSessionState {
    onMain(^{
      gamecore_resetSessionState();
    });
}

- (void)setDebugLogPath:(NSString *)path {
    onMain(^{
      gamecore_setDebugLogPath(path.fileSystemRepresentation);
      if (path != nil) {
          captureOutput(path.fileSystemRepresentation);
      }
    });
}

- (void)fetchStatus:(void (^)(NSDictionary<NSString *, id> *))reply {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!gCoreOpen) {
          reply(@{});
          return;
      }
      reply(@{
          EmpoGameProcessStatusGameReady : @(gamecore_isGameReady() != 0),
          EmpoGameProcessStatusAverageFPS : @(gamecore_getAverageFPS()),
          EmpoGameProcessStatusTargetFPS : @(gamecore_getTargetFPS()),
          EmpoGameProcessStatusTitle : text(gamecore_getGameTitle()),
          EmpoGameProcessStatusDetails : text(gamecore_getDetails()),
          EmpoGameProcessStatusCheats : @(gamecore_getCheatsEnabled()),
          EmpoGameProcessStatusFastForward : @(gamecore_getFastForwardMultiplier()),
          EmpoGameProcessStatusMemoryFootprint : @(memoryFootprint()),
      });
    });
}

- (void)quit {
    _exit(0);
}

@end

BOOL EmpoGameProcessAccept(NSXPCConnection *connection) {
    if (gConnection != nil) {
        return NO;
    }
    gConnection = connection;
    connection.exportedInterface = EmpoGameProcessInterface();
    connection.exportedObject = [EmpoGameProcessService new];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(EmpoGameProcessHost)];
    // The app ended, or closed the connection. Nothing else can reach
    // this game.
    connection.invalidationHandler = ^{
      _exit(0);
    };
    [connection resume];
    return YES;
}
