// Test host for the PSDK core.
//
// The app has no interface. It owns UIApplicationMain, then runs
// psdk_run on a worker thread. SFML's iOS window code marshals every
// UIKit call to the main thread with dispatch_sync, so the main thread
// has to stay in its run loop and answer them. A host that called
// psdk_run from the main thread would deadlock on the first window.
//
// SFML creates its own UIWindow above this app's, so this host needs no
// view of its own.
//
// Two variables, both read at launch:
//
//   PSDK_GAME      the game folder, relative to Documents.
//                  "Game" by default.
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
static char *gPreludePath;

static void *runGame(void *unused) {
    (void)unused;
    int result = psdk_run(gGamePath, gPreludePath);
    fprintf(stderr, "[host] psdk_run returned %d\n", result);
    // The bundle holds no interface to go back to, and the run loop
    // would keep the process alive forever. Leave with the core's
    // result so the driving script can read it.
    exit(result == 0 ? 0 : 1);
}

@interface PsdkTestHostDelegate : UIResponder <UIApplicationDelegate>
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

    const char *wantPrelude = getenv("PSDK_PRELUDE");
    NSString *prelude = (wantPrelude && !*wantPrelude)
                            ? nil
                            : [NSBundle.mainBundle.resourcePath
                                  stringByAppendingPathComponent:
                                      (wantPrelude && *wantPrelude) ? @(wantPrelude)
                                                                    : @"prelude.rb"];
    gPreludePath = prelude ? strdup(prelude.fileSystemRepresentation) : NULL;

    fprintf(stderr, "[host] game=%s prelude=%s\n", gGamePath,
            gPreludePath ? gPreludePath : "(none)");

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
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass(PsdkTestHostDelegate.class));
    }
}
