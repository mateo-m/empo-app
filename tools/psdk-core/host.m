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
// Four variables, all read at launch:
//
//   PSDK_GAME      the game folder, relative to Documents.
//                  "Game" by default.
// The core's Ruby support folder comes from PsdkTests.app/PsdkSupport,
// which the build script copies out of the psdk-support make target.
//
//   PSDK_KEYS      key presses to inject. scheduleKeys gives the format.
//
//   PSDK_PRELUDE   a Ruby file in the bundle that runs before Game.rb.
//                  "prelude.rb" by default. Set it empty to run none.
//
//   PSDK_RUN_FOR   seconds before the host leaves. A released game never
//                  returns from its own loop, so a run without a limit
//                  never ends. Unset or 0 means no limit.
//
//   PSDK_ROTATE    the second at which to run the rotation test.
//                  scheduleRotation says what it does and does not do.

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

// PSDK_KEYS drives the game without a person at the keyboard. Its
// format is "seconds:scancode" pairs joined by commas, and the numbers
// are SFML scancodes, the same space psdk_inject_scancode takes.
//
// The press lasts 150 ms. PSDK reads a button as triggered when it is
// down on one frame and was up on the one before, so a press has to
// cover at least one frame at 60 Hz. There is no signal to wait for
// here: the injector is one-way and the game never reports that it
// read the key.
static void scheduleKeys(const char *spec) {
    if (!spec || !*spec) {
        return;
    }
    for (NSString *pair in [@(spec) componentsSeparatedByString:@","]) {
        NSArray<NSString *> *parts = [pair componentsSeparatedByString:@":"];
        if (parts.count != 2) {
            continue;
        }
        double when = parts[0].doubleValue;
        int scancode = parts[1].intValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(when * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fprintf(stderr, "[host] key down %d at %.1fs\n", scancode, when);
            psdk_inject_scancode(scancode, 1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                psdk_inject_scancode(scancode, 0);
            });
        });
    }
}

static UIWindow *gHostWindow;

// A turn of the device runs two paths in SFML. The notification reaches
// deviceOrientationDidChange:, which forwards a Resized event to the
// game. The new frame reaches SFView's layoutSubviews, which rebuilds
// the render buffers and replaces the EGL surface under the game
// thread. PSDK_ROTATE drives both.
//
// It cannot turn the real device. This machine has only headless
// simctl, with no Simulator application, and simctl has no rotate
// command. UIDevice's orientation is read-only and ignores a KVC write,
// so the device stays in portrait. Swapping the SFML view's width and
// height and forcing a layout runs the same code a turn would, and
// posting the notification runs the other path. What this does not
// cover is UIKit's own choice of interface orientation.
static void scheduleRotation(const char *spec) {
    if (!spec || !*spec) {
        return;
    }
    double when = @(spec).doubleValue;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(when * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIDevice *device = UIDevice.currentDevice;
        fprintf(stderr, "[host] rotation test at %.1fs, generating=%d orientation=%ld\n",
                when, device.isGeneratingDeviceOrientationNotifications ? 1 : 0,
                (long)device.orientation);
        [NSNotificationCenter.defaultCenter
            postNotificationName:UIDeviceOrientationDidChangeNotification
                          object:device];

        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window == gHostWindow) {
                continue;
            }
            UIView *view = window.rootViewController.view ?: window.subviews.firstObject;
            if (!view) {
                continue;
            }
            CGRect frame = view.frame;
            fprintf(stderr, "[host] laying out %.0fx%.0f as %.0fx%.0f\n",
                    frame.size.width, frame.size.height, frame.size.height,
                    frame.size.width);
            view.frame = CGRectMake(frame.origin.x, frame.origin.y,
                                    frame.size.height, frame.size.width);
            [view layoutIfNeeded];
            view.frame = frame;
            [view layoutIfNeeded];
        }
    });
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

    scheduleKeys(getenv("PSDK_KEYS"));
    scheduleRotation(getenv("PSDK_ROTATE"));

    const char *runFor = getenv("PSDK_RUN_FOR");
    double seconds = runFor ? atof(runFor) : 0;
    if (seconds > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fprintf(stderr, "[host] run limit reached at %.1fs\n", seconds);
            exit(0);
        });
    }

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UIViewController alloc] init];
    self.window.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];
    gHostWindow = self.window;

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
