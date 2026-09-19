// Test host for the PSDK core.
//
// The app has no interface. It owns UIApplicationMain, then runs
// psdk_run on a worker thread. SFML's iOS window code marshals every
// UIKit call to the main thread with dispatch_sync, so the main thread
// has to stay in its run loop and answer them. A host that called
// psdk_run from the main thread would deadlock on the first window.
//
// The host still makes one empty UIWindow. iOS keeps its launch screen
// over the app until the app puts a window on screen, and SFML's own
// window does not count for that. Without this window the game renders
// and every eglSwapBuffers succeeds, but the display stays black.
// Empo has a real window already, so this only matters for the test.
//
// Two variables, both read at launch:
//
//   PSDK_GAME      the game folder, relative to Documents.
//                  "Game" by default.
// The core's Ruby support folder comes from PsdkTests.app/PsdkSupport,
// which the build script copies out of the psdk-support make target.
//
//   PSDK_PRELUDE   a Ruby file in the bundle that runs before Game.rb.
//                  "prelude.rb" by default. Set it empty to run none.

#include <pthread.h>
#include <stdlib.h>

#import <UIKit/UIKit.h>

#include "psdk_core.h"

// Ruby's parser and the PSDK boot scripts recurse deeply. The default
// 512 KB worker stack overflows. mkxp-z gives its RGSS thread the same
// 16 MB.
static const size_t kWorkerStackBytes = 16 * 1024 * 1024;

static char *gGamePath;
static char *gSupportPath;
static char *gPreludePath;
static int gArgc;
static char **gArgv;

static void *runGame(void *unused) {
    (void)unused;
    int result = psdk_run(gArgc, gArgv, gGamePath, gSupportPath, gPreludePath);
    fprintf(stderr, "[host] psdk_run returned %d\n", result);
    // The bundle holds no interface to go back to, and the run loop
    // would keep the process alive forever. Leave with the core's
    // result so the driving script can read it.
    exit(result == 0 ? 0 : 1);
}

@interface PsdkTestHostDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation PsdkTestHostDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

    const char *wantGame = getenv("PSDK_GAME");
    NSString *game = [documents
        stringByAppendingPathComponent:(wantGame && *wantGame) ? @(wantGame) : @"Game"];
    if (![NSFileManager.defaultManager fileExistsAtPath:game]) {
        fprintf(stderr, "[host] no game folder at %s\n", game.UTF8String);
        exit(2);
    }
    gGamePath = strdup(game.fileSystemRepresentation);

    NSString *support = [NSBundle.mainBundle.resourcePath
        stringByAppendingPathComponent:@"PsdkSupport"];
    if (![NSFileManager.defaultManager fileExistsAtPath:support]) {
        fprintf(stderr, "[host] no support folder at %s\n", support.UTF8String);
        exit(4);
    }
    gSupportPath = strdup(support.fileSystemRepresentation);

    const char *wantPrelude = getenv("PSDK_PRELUDE");
    NSString *prelude = (wantPrelude && !*wantPrelude)
                            ? nil
                            : [NSBundle.mainBundle.resourcePath
                                  stringByAppendingPathComponent:
                                      (wantPrelude && *wantPrelude) ? @(wantPrelude)
                                                                    : @"prelude.rb"];
    gPreludePath = prelude ? strdup(prelude.fileSystemRepresentation) : NULL;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UIViewController alloc] init];
    self.window.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];

    fprintf(stderr, "[host] game=%s support=%s prelude=%s\n", gGamePath,
            gSupportPath, gPreludePath ? gPreludePath : "(none)");

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, kWorkerStackBytes);
    pthread_t worker;
    if (pthread_create(&worker, &attr, runGame, NULL) != 0) {
        fprintf(stderr, "[host] cannot start the worker thread\n");
        exit(3);
    }
    pthread_attr_destroy(&attr);
    pthread_detach(worker);
    return YES;
}

@end

int main(int argc, char **argv) {
    gArgc = argc;
    gArgv = argv;
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass(PsdkTestHostDelegate.class));
    }
}
