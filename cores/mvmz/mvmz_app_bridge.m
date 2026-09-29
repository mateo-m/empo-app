// The launcher interface for the RPG Maker MV and MZ core. The core,
// mvmz_core.h from mvmz-apple-mobile, runs the game in a web view. This
// file puts the web view in its own window and in the launcher's
// region, and answers the launcher calls with the core's calls.
//
// Every function here runs on the main thread. The launcher calls them
// from the main actor, and the core calls back on the main thread.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#include "GameCore.h"
#include "mvmz_core.h"

typedef struct {
    void *fn;
    void *userdata;
} Callback;

static Callback gFrameRendered;
static Callback gEngineTerminated;
static Callback gGameRectChanged;
static Callback gErrorMessage;
static Callback gInfoMessage;
static Callback gPaused;
static Callback gResumed;
static Callback gTextInputMode;

static NSString *gGamePath;
static NSFileHandle *gLog;
static UIWindow *gWindow;
static WKWebView *gWebView;

static BOOL gGameReady;
static BOOL gTerminated;
static BOOL gExitedCleanly;
static BOOL gPausedFlag;
static BOOL gCheatsEnabled;
static int gFastForward = 1;
static GameCoreVerticalAlignment gVerticalAlignment = GAMECORE_VALIGN_TOP_CENTER;
static UIEdgeInsets gSafeArea;
static BOOL gHasHostRegion;
static BOOL gHostRegionPortrait;
static CGRect gHostRegion;
static CGSize gGameSize;

static NSLock *gSnapshotLock;
static NSData *gSnapshotRGBA;
static int gSnapshotW;
static int gSnapshotH;

static void logLine(NSString *line) {
    NSLog(@"[mvmz] %@", line);
    [gLog writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
}

// Puts the picture in the launcher's region and tells the launcher
// where it landed. The same rules as placeOutputRegion in
// psdk_app_bridge.cpp, in points: the host view is the size of the
// launcher's window once GameViewEmbedder moves it there.
//
// The game scales its canvas to the page and centres it, so the web
// view gets the picture rect itself and the page has no margin.
static void placeWebView(void) {
    UIView *host = gWebView.superview;
    const CGRect bounds = host.bounds;
    if (!host || CGRectIsEmpty(bounds)) {
        return;
    }
    const BOOL portrait = bounds.size.height > bounds.size.width;
    const BOOL hostRegionApplies = gHasHostRegion && gHostRegionPortrait == portrait;

    CGRect box;
    if (hostRegionApplies) {
        box = CGRectMake(gHostRegion.origin.x * bounds.size.width, gHostRegion.origin.y * bounds.size.height,
                         gHostRegion.size.width * bounds.size.width,
                         gHostRegion.size.height * bounds.size.height);
    } else {
        // Landscape keeps the full height, as in the other two cores.
        UIEdgeInsets insets = gSafeArea;
        if (!portrait) {
            insets.top = 0;
            insets.bottom = 0;
        }
        box = UIEdgeInsetsInsetRect(bounds, insets);
    }
    box = CGRectIntersection(box, bounds);
    if (CGRectIsEmpty(box)) {
        return;
    }

    CGRect picture = box;
    // ponytail: always fits. A stretched picture also needs MV and MZ
    // to map touches through the stretch.
    if (gGameSize.width > 0 && gGameSize.height > 0) {
        const CGFloat scale = MIN(box.size.width / gGameSize.width, box.size.height / gGameSize.height);
        picture.size = CGSizeMake(gGameSize.width * scale, gGameSize.height * scale);
        picture.origin.x = CGRectGetMidX(box) - picture.size.width / 2;
        picture.origin.y = CGRectGetMidY(box) - picture.size.height / 2;
    }
    if (!hostRegionApplies && portrait) {
        const CGFloat top = box.origin.y;
        const CGFloat centre = picture.origin.y;
        switch (gVerticalAlignment) {
        case GAMECORE_VALIGN_TOP:
            picture.origin.y = top;
            break;
        case GAMECORE_VALIGN_CENTER:
            break;
        default:
            picture.origin.y = (top + centre) / 2;
            break;
        }
    }

    if (CGRectEqualToRect(gWebView.frame, picture)) {
        return;
    }
    gWebView.frame = picture;
    if (gGameRectChanged.fn) {
        ((gamecore_GameRectChangedCallback)gGameRectChanged.fn)(picture.origin.x, picture.origin.y,
                                                                picture.size.width, picture.size.height,
                                                                gGameRectChanged.userdata);
    }
}

__attribute__((visibility("hidden")))
@interface MvmzHostView : UIView
@end

@implementation MvmzHostView
- (void)layoutSubviews {
    [super layoutSubviews];
    placeWebView();
}
@end

__attribute__((visibility("hidden")))
@interface MvmzViewController : UIViewController
@end

@implementation MvmzViewController
- (void)loadView {
    self.view = [[MvmzHostView alloc] init];
    self.view.backgroundColor = UIColor.blackColor;
}
@end

static void fire(Callback cb) {
    if (cb.fn) {
        ((void (*)(void *))cb.fn)(cb.userdata);
    }
}

static void terminate(BOOL clean) {
    if (gTerminated) {
        return;
    }
    gTerminated = YES;
    gExitedCleanly = clean;
    fire(gEngineTerminated);
}

// Converts the snapshot WebKit makes to the RGBA rows the launcher
// reads, then tells the launcher the game is paused.
static void storeSnapshotAndReportPause(UIImage *image, NSError *error) {
    CGImageRef cg = image.CGImage;
    if (!cg) {
        logLine([NSString stringWithFormat:@"paused with no picture: %@", error.localizedDescription]);
    } else {
        const size_t w = CGImageGetWidth(cg);
        const size_t h = CGImageGetHeight(cg);
        NSMutableData *rgba = [NSMutableData dataWithLength:w * h * 4];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(rgba.mutableBytes, w, h, 8, w * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(space);
        [gSnapshotLock lock];
        gSnapshotRGBA = rgba;
        gSnapshotW = (int)w;
        gSnapshotH = (int)h;
        [gSnapshotLock unlock];
    }
    fire(gPaused);
}

static void frameRendered(void *userdata) {
    if (!gGameReady) {
        gGameReady = YES;
        logLine(@"first frame");
    }
    fire(gFrameRendered);
}

static void gameSizeChanged(int width, int height, void *userdata) {
    gGameSize = CGSizeMake(width, height);
    placeWebView();
}

static void gameExited(int clean, void *userdata) {
    terminate(clean);
}

static void gameAlert(const char *message, void *userdata) {
    if (gInfoMessage.fn) {
        ((gamecore_InfoMessageCallback)gInfoMessage.fn)(message, gInfoMessage.userdata);
    }
}

static void coreLog(const char *line, void *userdata) {
    logLine(@(line));
}

static void takeSnapshot(void *userdata) {
    [gWebView takeSnapshotWithConfiguration:nil
                          completionHandler:^(UIImage *image, NSError *error) {
                              storeSnapshotAndReportPause(image, error);
                          }];
}

// MARK: - Starting the game

// Makes the window, starts the game in the core's web view, then
// returns. The launcher keeps the main thread in its run loop, and
// WebKit needs it there.
int gamecore_run_app(int argc, char **argv) {
    NSString *root = gGamePath;
    if (root.length == 0) {
        logLine(@"no game path");
        return -1;
    }

    gamecore_killSession();

    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class]) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }
    gWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gWindow.rootViewController = [[MvmzViewController alloc] init];

    mvmz_set_frame_callback(frameRendered, NULL);
    mvmz_set_size_callback(gameSizeChanged, NULL);
    mvmz_set_exit_callback(gameExited, NULL);
    mvmz_set_alert_callback(gameAlert, NULL);
    mvmz_set_log_callback(coreLog, NULL);
    // The launcher passes Games/<name>/Game, and <name> is the game's identity.
    NSString *gameId = root.stringByDeletingLastPathComponent.lastPathComponent;
    gWebView = (__bridge WKWebView *)mvmz_start(root.UTF8String, gameId.UTF8String);
#if DEBUG
    gWebView.inspectable = YES;
#endif
    gWebView.frame = gWindow.rootViewController.view.bounds;
    [gWindow.rootViewController.view addSubview:gWebView];
    // WebKit suspends the page of a web view that is in no visible
    // window. The app window stays above this one until the first frame.
    gWindow.hidden = NO;
    return 0;
}

void gamecore_killSession(void) {
    mvmz_stop();
    gWebView = nil;
    gWindow.hidden = YES;
    gWindow = nil;
    gamecore_resetSessionState();
}

void gamecore_setGamePath(const char *path) {
    gGamePath = path ? @(path) : nil;
}

// MARK: - Input

void gamecore_injectKeyEvent(int scancode, int pressed) {
    mvmz_inject_key(scancode, pressed);
}

// MARK: - The window

void *gamecore_getGameWindow(void) {
    return (__bridge void *)gWindow;
}

// MARK: - Callbacks

void gamecore_setFrameRenderedCallback(gamecore_FrameRenderedCallback cb, void *userdata) {
    gFrameRendered = (Callback){(void *)cb, userdata};
}

void gamecore_setEngineTerminatedCallback(gamecore_EngineTerminatedCallback cb, void *userdata) {
    gEngineTerminated = (Callback){(void *)cb, userdata};
}

void gamecore_setGameRectChangedCallback(gamecore_GameRectChangedCallback cb, void *userdata) {
    gGameRectChanged = (Callback){(void *)cb, userdata};
}

void gamecore_setErrorMessageCallback(gamecore_ErrorMessageCallback cb, void *userdata) {
    gErrorMessage = (Callback){(void *)cb, userdata};
}

void gamecore_setInfoMessageCallback(gamecore_InfoMessageCallback cb, void *userdata) {
    gInfoMessage = (Callback){(void *)cb, userdata};
}

void gamecore_setPausedCallback(gamecore_PausedCallback cb, void *userdata) {
    gPaused = (Callback){(void *)cb, userdata};
}

void gamecore_setResumedCallback(gamecore_ResumedCallback cb, void *userdata) {
    gResumed = (Callback){(void *)cb, userdata};
}

void gamecore_setTextInputModeCallback(gamecore_TextInputModeCallback cb, void *userdata) {
    gTextInputMode = (Callback){(void *)cb, userdata};
}

// MARK: - Session state

int gamecore_isGameReady(void) {
    return gGameReady;
}
int gamecore_isEngineTerminated(void) {
    return gTerminated;
}
int gamecore_didEngineExitCleanly(void) {
    return gExitedCleanly;
}

// A hung game still leaves WebKit's main thread free, and the launcher
// alert for a hang says to close the app, which a web page never needs.
int gamecore_isEngineHung(void) {
    return 0;
}

void gamecore_resetSessionState(void) {
    gGameReady = NO;
    gTerminated = NO;
    gExitedCleanly = NO;
    gPausedFlag = NO;
    gHasHostRegion = NO;
    gGameSize = CGSizeZero;
    gFastForward = 1;
    gCheatsEnabled = NO;
    if (!gSnapshotLock) {
        gSnapshotLock = [[NSLock alloc] init];
    }
    [gSnapshotLock lock];
    gSnapshotRGBA = nil;
    [gSnapshotLock unlock];
}

// MARK: - Pause

void gamecore_requestPause(void) {
    if (gPausedFlag) {
        return;
    }
    gPausedFlag = YES;
    mvmz_pause(takeSnapshot, NULL);
}

void gamecore_requestResume(void) {
    gPausedFlag = NO;
    mvmz_resume();
    [gSnapshotLock lock];
    gSnapshotRGBA = nil;
    [gSnapshotLock unlock];
    fire(gResumed);
}

bool gamecore_isPaused(void) {
    return gPausedFlag;
}

bool gamecore_getSnapshotSize(int *width, int *height) {
    [gSnapshotLock lock];
    const bool has = gSnapshotRGBA != nil;
    if (has && width)
        *width = gSnapshotW;
    if (has && height)
        *height = gSnapshotH;
    [gSnapshotLock unlock];
    return has;
}

bool gamecore_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height) {
    [gSnapshotLock lock];
    const bool fits = dest && gSnapshotRGBA && destSize >= 0 && (NSUInteger)destSize >= gSnapshotRGBA.length;
    if (fits) {
        memcpy(dest, gSnapshotRGBA.bytes, gSnapshotRGBA.length);
        if (width)
            *width = gSnapshotW;
        if (height)
            *height = gSnapshotH;
    }
    [gSnapshotLock unlock];
    return fits;
}

// MARK: - Text input

// An MV or MZ game reads no typed text through the launcher. A plugin
// that wants text puts a text field in the page, and WebKit brings up
// the keyboard for it.
int gamecore_isTextInputActive(void) {
    return 0;
}
void gamecore_pushTextInput(const char *utf8) {
}

// MARK: - Alerts

void gamecore_signalErrorDismissed(void) {
}
void gamecore_signalInfoDismissed(void) {
}

// MARK: - What the launcher pushes

void gamecore_setDebugLogPath(const char *path) {
    [gLog closeFile];
    gLog = nil;
    if (!path || !path[0]) {
        return;
    }
    gLog = [NSFileHandle fileHandleForWritingAtPath:@(path)];
    [gLog seekToEndOfFile];
    logLine(@"log is attached");
}

// The launcher sends the same overlay it gives mkxp-z. It writes
// "smoothScaling" as a number or a boolean.
void gamecore_setConfigOverlayJSON(const char *jsonUTF8) {
    NSDictionary *overlay = nil;
    if (jsonUTF8) {
        overlay = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:jsonUTF8
                                                                         length:strlen(jsonUTF8)]
                                                  options:0
                                                    error:nil];
    }
    if (![overlay isKindOfClass:NSDictionary.class]) {
        overlay = @{};
    }
    id smooth = overlay[@"smoothScaling"];
    mvmz_set_smooth([smooth isKindOfClass:NSNumber.class] && [smooth boolValue]);
}

void gamecore_setFastForwardMultiplier(int multiplier) {
    gFastForward = multiplier;
    mvmz_set_speed(multiplier);
}

int gamecore_getFastForwardMultiplier(void) {
    return gFastForward;
}

void gamecore_setHostViewportRegion(float x, float y, float w, float h, bool isPortrait) {
    gHostRegion = CGRectMake(x, y, w, h);
    gHostRegionPortrait = isPortrait;
    gHasHostRegion = YES;
    placeWebView();
}

void gamecore_clearHostViewportRegion(void) {
    gHasHostRegion = NO;
    placeWebView();
}

void gamecore_setSafeAreaInsets(float top, float bottom, float left, float right) {
    gSafeArea = UIEdgeInsetsMake(top, left, bottom, right);
    placeWebView();
}

void gamecore_applySessionConfig(const GameCoreSessionConfig *config) {
    if (!config) {
        return;
    }
    gVerticalAlignment = config->verticalAlignment;
    placeWebView();
}

GameCoreVerticalAlignment gamecore_getVerticalAlignment(void) {
    return gVerticalAlignment;
}

void gamecore_setCheatsEnabled(bool enabled) {
    gCheatsEnabled = enabled;
}
bool gamecore_getCheatsEnabled(void) {
    return gCheatsEnabled;
}

// This core has no keys. Every key writes a warning to the log.
void gamecore_setSetting(const char *key, const char *value) {
    NSLog(@"[mvmz] unknown setting %s", key ?: "(null)");
}

// An MV or MZ game has nothing these could reach.
void gamecore_setLauncherIdentity(const char *name) {
}
void gamecore_setCABundlePath(const char *path) {
}
void gamecore_setShowViewportBounds(bool enabled) {
}
void gamecore_setViewportBoundsColor(float r, float g, float b, float a) {
}
void gamecore_setGameControllerCaptureEnabled(bool enabled) {
}
void gamecore_setTouchMouseEnabled(bool enabled) {
}

// MARK: - What the launcher reads

const char *gamecore_getGameTitle(void) {
    return "";
}
const char *gamecore_getDetails(void) {
    return mvmz_details();
}
int gamecore_getTargetFPS(void) {
    return 60;
}

double gamecore_getAverageFPS(void) {
    return mvmz_fps();
}
