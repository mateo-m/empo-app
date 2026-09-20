// Test host for the mkxp-z core.
//
// The host owns UIApplicationMain and its own delegate. It does not
// link the engine. It opens Frameworks/MkxpCore.framework/MkxpCore with
// dlopen when the game starts, then calls mkxp_run_app on the main
// thread. Empo does the same on the game the user picks, so the test
// host and the launcher take one path.
//
// mkxp_run_app does not return. SDL pumps the UIKit run loop from
// inside SDL_PumpEvents, which is how the timers below still fire and
// how the host window still draws. This is the opposite of the PSDK
// host, which runs its core on a worker thread because SFML marshals
// every UIKit call to the main thread.
//
// Five variables, all read at launch:
//
//   MKXP_GAME      the game folder, relative to Documents.
//                  "Game" by default.
//
//   MKXP_LOAD_AT   the second at which to open the core and start the
//                  game. 2 by default. It stands in for the moment the
//                  user taps a game in Empo.
//
//   MKXP_KEYS      key presses to inject. scheduleKeys gives the format.
//
//   MKXP_RUN_FOR   seconds before the host leaves. A game never returns
//                  from its own loop, so a run without a limit never
//                  ends. Unset or 0 means no limit.

#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

#import <UIKit/UIKit.h>

static int (*gMkxpRunApp)(int, char **);
static void (*gMkxpSetGamePath)(const char *);
static void (*gMkxpInjectKeyEvent)(int, int);

static char *gGamePath;
static int gArgc;
static char **gArgv;

// MKXP_KEYS drives the game without a person at the keyboard. Its
// format is "seconds:scancode" pairs joined by commas, and the numbers
// are the MKXP_SCANCODE_* values in app_bridge.h, which are SDL
// scancodes.
//
// The press lasts 150 ms. The engine reads a button as triggered when
// it is down on one frame and was up on the one before, so a press has
// to cover at least one frame at 60 Hz. There is no signal to wait for
// here: the injector is one-way and the game never reports that it read
// the key.
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
            gMkxpInjectKeyEvent(scancode, 1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                gMkxpInjectKeyEvent(scancode, 0);
            });
        });
    }
}

static void openCore(void) {
    NSString *core = [NSBundle.mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"MkxpCore.framework"];

    // RTLD_LOCAL keeps the core's names out of the global namespace, so
    // a second core opened later cannot bind to them.
    void *image = dlopen([core stringByAppendingPathComponent:@"MkxpCore"].fileSystemRepresentation,
                         RTLD_NOW | RTLD_LOCAL);
    if (!image) {
        fprintf(stderr, "[host] cannot open the core: %s\n", dlerror());
        exit(5);
    }
    gMkxpRunApp = dlsym(image, "mkxp_run_app");
    gMkxpSetGamePath = dlsym(image, "mkxp_setGamePath");
    gMkxpInjectKeyEvent = dlsym(image, "mkxp_injectKeyEvent");
    if (!gMkxpRunApp || !gMkxpSetGamePath || !gMkxpInjectKeyEvent) {
        fprintf(stderr, "[host] the core is missing a symbol the host needs\n");
        exit(6);
    }
}

@interface MkxpTestHostDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation MkxpTestHostDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

    const char *wantGame = getenv("MKXP_GAME");
    NSString *game = [documents
        stringByAppendingPathComponent:(wantGame && *wantGame) ? @(wantGame) : @"Game"];
    if (![NSFileManager.defaultManager fileExistsAtPath:game]) {
        fprintf(stderr, "[host] no game folder at %s\n", game.UTF8String);
        exit(2);
    }
    gGamePath = strdup(game.fileSystemRepresentation);

    const char *runFor = getenv("MKXP_RUN_FOR");
    double seconds = runFor ? atof(runFor) : 0;
    if (seconds > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fprintf(stderr, "[host] run limit reached at %.1fs\n", seconds);
            // _exit, not exit. The game thread runs Ruby code. exit()
            // runs the atexit handlers and the static destructors, which
            // free the Ruby VM under that thread.
            _exit(0);
        });
    }

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UIViewController alloc] init];
    self.window.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];

    const char *loadAt = getenv("MKXP_LOAD_AT");
    [self performSelector:@selector(openCoreAndRun)
               withObject:nil
               afterDelay:loadAt ? atof(loadAt) : 2.0];

    return YES;
}

// A run loop timer, not dispatch_after. mkxp_run_app never returns, so
// a main queue block that calls it blocks the main queue for the whole
// session. The engine's RGSS thread then deadlocks the first time it
// calls mkxp_getScreenScale, which dispatch_syncs to that queue.
// SDLUIKitDelegate reaches SDL_main the same way
// (SDL_uikitappdelegate.m:467).
- (void)openCoreAndRun {
    fprintf(stderr, "[host] opening the core\n");
    openCore();
    scheduleKeys(getenv("MKXP_KEYS"));
    gMkxpSetGamePath(gGamePath);
    int result = gMkxpRunApp(gArgc, gArgv);
    fprintf(stderr, "[host] mkxp_run_app returned %d\n", result);
    _exit(result == 0 ? 0 : 1);
}

@end

int main(int argc, char *argv[]) {
    gArgc = argc;
    gArgv = argv;
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass(MkxpTestHostDelegate.class));
    }
}
