#import "GameProcessService.h"

#include <crt_externs.h>

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

static void onFrameRendered(void *userdata) {
    [host() frameRendered];
}

@interface EmpoGameProcessService : NSObject <EmpoGameProcess>
@end

@implementation EmpoGameProcessService

- (void)openCore:(NSString *)framework
       bookmarks:(NSArray<NSData *> *)bookmarks
           reply:(void (^)(NSString *_Nullable))reply {
    for (NSData *bookmark in bookmarks) {
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:&error];
        if (url == nil) {
            reply([NSString stringWithFormat:@"cannot open a folder of the app: %@", error]);
            return;
        }
        // The access stays for the life of the process.
        if (![url startAccessingSecurityScopedResource]) {
            NSLog(@"[game-process] no scoped access to %@", url.path);
        }
    }
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

// A core may hold the main thread until the game ends, so it runs from
// a run loop callout and not from a block on the main queue
// (GameCore.h). The main queue block puts it after every call before it.
- (void)runApp {
    onMain(^{
      CFRunLoopRef mainLoop = CFRunLoopGetMain();
      CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
        gamecore_run_app(*_NSGetArgc(), *_NSGetArgv());
      });
      CFRunLoopWakeUp(mainLoop);
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
    connection.remoteObjectInterface = EmpoGameProcessHostInterface();
    // The app ended, or closed the connection. Nothing else can reach
    // this game.
    connection.invalidationHandler = ^{
      _exit(0);
    };
    [connection resume];
    return YES;
}
