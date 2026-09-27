// The launcher interface for the RPG Maker MV and MZ core.
//
// An MV or MZ game is a web page: the game folder carries its own
// engine as JavaScript. So this core runs no engine of its own. It
// shows the game's index.html in a WKWebView, serves the game folder
// through MvmzFileServer, and loads runtime.js before the game's
// scripts. runtime.js makes the page look like the NW.js desktop
// runtime the game shipped for, and answers the launcher calls that
// reach the game (keys, pause, fast forward).
//
// Every function here runs on the main thread. The launcher calls them
// from the main actor, and WebKit calls back on the main thread.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>

#include "mvmz_app_bridge.h"
#import "MvmzFileServer.h"

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
static BOOL gSmoothScaling;
static BOOL gCheatsEnabled;
static int gFastForward = 1;
static MvmzVerticalAlignment gVerticalAlignment = MVMZ_VALIGN_TOP_CENTER;
static UIEdgeInsets gSafeArea;
static BOOL gHasHostRegion;
static BOOL gHostRegionPortrait;
static CGRect gHostRegion;
static CGSize gGameSize;

static NSLock *gSnapshotLock;
static NSData *gSnapshotRGBA;
static int gSnapshotW;
static int gSnapshotH;

static double gFps;
static char *gDetails;

static void logLine(NSString *line) {
    NSLog(@"[mvmz] %@", line);
    [gLog writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
}

static void runJS(NSString *script) {
    [gWebView evaluateJavaScript:script completionHandler:nil];
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
        const CGFloat scale =
            MIN(box.size.width / gGameSize.width, box.size.height / gGameSize.height);
        picture.size = CGSizeMake(gGameSize.width * scale, gGameSize.height * scale);
        picture.origin.x = CGRectGetMidX(box) - picture.size.width / 2;
        picture.origin.y = CGRectGetMidY(box) - picture.size.height / 2;
    }
    if (!hostRegionApplies && portrait) {
        const CGFloat top = box.origin.y;
        const CGFloat centre = picture.origin.y;
        switch (gVerticalAlignment) {
        case MVMZ_VALIGN_TOP:
            picture.origin.y = top;
            break;
        case MVMZ_VALIGN_CENTER:
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
        ((mvmz_GameRectChangedCallback)gGameRectChanged.fn)(
            picture.origin.x, picture.origin.y, picture.size.width, picture.size.height,
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

__attribute__((visibility("hidden")))
@interface MvmzMessages : NSObject <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@end

@implementation MvmzMessages

// runtime.js posts one dictionary for each event, keyed by "type".
- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSString *type = body[@"type"];
    if ([type isEqualToString:@"frame"]) {
        if (!gGameReady) {
            gGameReady = YES;
            logLine(@"first frame");
        }
        fire(gFrameRendered);
    } else if ([type isEqualToString:@"fps"]) {
        gFps = [body[@"fps"] doubleValue];
    } else if ([type isEqualToString:@"details"]) {
        NSMutableArray<NSString *> *lines = [body[@"lines"] mutableCopy];
        NSString *device = MTLCreateSystemDefaultDevice().name;
        if (device) [lines addObject:device];
        free(gDetails);
        gDetails = strdup([lines componentsJoinedByString:@"\n"].UTF8String);
    } else if ([type isEqualToString:@"size"]) {
        gGameSize = CGSizeMake([body[@"width"] doubleValue], [body[@"height"] doubleValue]);
        logLine([NSString stringWithFormat:@"game size %.0fx%.0f", gGameSize.width, gGameSize.height]);
        placeWebView();
    } else if ([type isEqualToString:@"log"]) {
        logLine([NSString stringWithFormat:@"%@", body[@"text"]]);
    } else if ([type isEqualToString:@"exit"]) {
        logLine(@"the game closed itself");
        terminate(YES);
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    logLine([NSString stringWithFormat:@"index.html did not load: %@", error]);
    terminate(NO);
}

// The web content process ran out of memory or crashed. The page is
// gone with it, and a reload would start the game from its title
// screen, so the session ends the way a crash of the other cores does.
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    logLine(@"the web content process stopped");
    terminate(NO);
}

// The game's own window.alert, for example a plugin that reports a
// missing file. WebKit shows nothing without a UI delegate.
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(void))completionHandler {
    logLine([NSString stringWithFormat:@"alert: %@", message]);
    mvmz_presentInfoAndWait(message.UTF8String);
    completionHandler();
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(BOOL))completionHandler {
    logLine([NSString stringWithFormat:@"confirm, answered yes: %@", message]);
    completionHandler(YES);
}

@end

static MvmzMessages *gMessages;
static MvmzFileServer *gFileServer;

// Each game gets its own origin, so localStorage and IndexedDB of one
// game are not visible to the next one. Empo passes
// Games/<name>/Game, and <name> is the game's identity.
static NSString *originHost(NSString *gameRoot) {
    NSData *name = [gameRoot.stringByDeletingLastPathComponent.lastPathComponent
        dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(name.bytes, (CC_LONG)name.length, digest);
    NSMutableString *host = [NSMutableString stringWithString:@"game-"];
    for (int i = 0; i < 16; i++) {
        [host appendFormat:@"%02x", digest[i]];
    }
    return host;
}

static NSString *ownResource(NSString *name) {
    NSBundle *bundle = [NSBundle bundleForClass:MvmzMessages.class];
    NSString *path = [bundle pathForResource:name ofType:nil];
    return path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
}

static NSString *jsonString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// MARK: - Starting the game

// Builds the web view and loads the game, then returns. The launcher
// keeps the main thread in its run loop, and WebKit needs it there.
int mvmz_run_app(int argc, char **argv) {
    NSString *root = gGamePath;
    if (root.length == 0) {
        logLine(@"no game path");
        return -1;
    }

    mvmz_killSession();

    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class]) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }
    gWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gWindow.rootViewController = [[MvmzViewController alloc] init];

    NSString *host = originHost(root);
    gFileServer = [[MvmzFileServer alloc] initWithRoot:root];
    gMessages = [[MvmzMessages alloc] init];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config setURLSchemeHandler:gFileServer forURLScheme:MvmzFileServer.scheme];
    // The game starts its music before the first touch, as it does on a
    // desktop.
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    config.allowsInlineMediaPlayback = YES;

    NSDictionary *settings = @{
        @"speed" : @(gFastForward),
        @"smooth" : @(gSmoothScaling),
        @"simulator" : @(TARGET_OS_SIMULATOR),
    };
    NSString *runtime = ownResource(@"runtime.js");
    NSString *source = [NSString stringWithFormat:@"window.__mvmzSettings = %@;\n%@", jsonString(settings),
                                                  runtime ?: @""];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:source
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES];
    [config.userContentController addUserScript:script];
    [config.userContentController addScriptMessageHandler:gMessages name:@"mvmz"];

    gWebView = [[WKWebView alloc] initWithFrame:gWindow.rootViewController.view.bounds
                                  configuration:config];
    // With the user agent of a phone, MV asks for .m4a audio that many
    // desktop games do not ship, MV drops its fixed update rate, and MZ
    // uses only 90% of the screen height.
    gWebView.customUserAgent =
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)";
    gWebView.navigationDelegate = gMessages;
    gWebView.UIDelegate = gMessages;
    gWebView.opaque = NO;
    gWebView.backgroundColor = UIColor.blackColor;
    gWebView.scrollView.scrollEnabled = NO;
    gWebView.scrollView.bounces = NO;
    gWebView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
#if DEBUG
    gWebView.inspectable = YES;
#endif
    [gWindow.rootViewController.view addSubview:gWebView];
    // WebKit suspends the page of a web view that is in no visible
    // window. The app window stays above this one until the first frame.
    gWindow.hidden = NO;

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/index.html", MvmzFileServer.scheme,
                                                                  host]];
    logLine([NSString stringWithFormat:@"boot %@ from %@", url, root]);
    [gWebView loadRequest:[NSURLRequest requestWithURL:url]];
    return 0;
}

// WebKit ends the page, with all of its JavaScript, when its web view
// goes. The message handler holds the web view until it is removed.
void mvmz_killSession(void) {
    [gWebView.configuration.userContentController removeAllScriptMessageHandlers];
    [gWebView stopLoading];
    [gWebView removeFromSuperview];
    gWebView = nil;
    gWindow.hidden = YES;
    gWindow = nil;
    gMessages = nil;
    gFileServer = nil;
    gFps = 0;
    free(gDetails);
    gDetails = NULL;
    mvmz_resetSessionState();
}

void mvmz_setGamePath(const char *path) {
    gGamePath = path ? @(path) : nil;
}

const char *mvmz_waitForGamePath(void) {
    return gGamePath.UTF8String;
}

// MARK: - Input

// runtime.js turns the scancode into the keyCode the game reads.
void mvmz_injectKeyEvent(int scancode, int pressed) {
    runJS([NSString stringWithFormat:@"__mvmz.key(%d,%d)", scancode, pressed]);
}

// MARK: - The window

void *mvmz_getGameWindow(void) {
    return (__bridge void *)gWindow;
}

// MARK: - Callbacks

void mvmz_setFrameRenderedCallback(mvmz_FrameRenderedCallback cb, void *userdata) {
    gFrameRendered = (Callback){(void *)cb, userdata};
}

void mvmz_setEngineTerminatedCallback(mvmz_EngineTerminatedCallback cb, void *userdata) {
    gEngineTerminated = (Callback){(void *)cb, userdata};
}

void mvmz_setGameRectChangedCallback(mvmz_GameRectChangedCallback cb, void *userdata) {
    gGameRectChanged = (Callback){(void *)cb, userdata};
}

void mvmz_setErrorMessageCallback(mvmz_ErrorMessageCallback cb, void *userdata) {
    gErrorMessage = (Callback){(void *)cb, userdata};
}

void mvmz_setInfoMessageCallback(mvmz_InfoMessageCallback cb, void *userdata) {
    gInfoMessage = (Callback){(void *)cb, userdata};
}

void mvmz_setPausedCallback(mvmz_PausedCallback cb, void *userdata) {
    gPaused = (Callback){(void *)cb, userdata};
}

void mvmz_setResumedCallback(mvmz_ResumedCallback cb, void *userdata) {
    gResumed = (Callback){(void *)cb, userdata};
}

void mvmz_setTextInputModeCallback(mvmz_TextInputModeCallback cb, void *userdata) {
    gTextInputMode = (Callback){(void *)cb, userdata};
}

// MARK: - Session state

int mvmz_isGameReady(void) { return gGameReady; }
int mvmz_isEngineTerminated(void) { return gTerminated; }
int mvmz_didEngineExitCleanly(void) { return gExitedCleanly; }

// A hung game still leaves WebKit's main thread free, and the launcher
// alert for a hang says to close the app, which a web page never needs.
int mvmz_isEngineHung(void) { return 0; }

void mvmz_resetSessionState(void) {
    gGameReady = NO;
    gTerminated = NO;
    gExitedCleanly = NO;
    gPausedFlag = NO;
    gHasHostRegion = NO;
    gGameSize = CGSizeZero;
    if (!gSnapshotLock) {
        gSnapshotLock = [[NSLock alloc] init];
    }
    [gSnapshotLock lock];
    gSnapshotRGBA = nil;
    [gSnapshotLock unlock];
}

// MARK: - Pause

// runtime.js holds the game's frames and suspends its audio. The
// snapshot is taken after that, so it shows the frame the game stopped
// on.
void mvmz_requestPause(void) {
    if (gPausedFlag) {
        return;
    }
    gPausedFlag = YES;
    [gWebView evaluateJavaScript:@"__mvmz.pause()"
               completionHandler:^(id result, NSError *error) {
                   [gWebView takeSnapshotWithConfiguration:nil
                                         completionHandler:^(UIImage *image, NSError *snapError) {
                                             storeSnapshotAndReportPause(image, snapError);
                                         }];
               }];
}

void mvmz_requestResume(void) {
    gPausedFlag = NO;
    runJS(@"__mvmz.resume()");
    [gSnapshotLock lock];
    gSnapshotRGBA = nil;
    [gSnapshotLock unlock];
    fire(gResumed);
}

bool mvmz_isPaused(void) { return gPausedFlag; }

bool mvmz_getSnapshotSize(int *width, int *height) {
    [gSnapshotLock lock];
    const bool has = gSnapshotRGBA != nil;
    if (has && width) *width = gSnapshotW;
    if (has && height) *height = gSnapshotH;
    [gSnapshotLock unlock];
    return has;
}

bool mvmz_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height) {
    [gSnapshotLock lock];
    const bool fits = dest && gSnapshotRGBA && destSize >= 0 && (NSUInteger)destSize >= gSnapshotRGBA.length;
    if (fits) {
        memcpy(dest, gSnapshotRGBA.bytes, gSnapshotRGBA.length);
        if (width) *width = gSnapshotW;
        if (height) *height = gSnapshotH;
    }
    [gSnapshotLock unlock];
    return fits;
}

// MARK: - Text input

// An MV or MZ game reads no typed text through the launcher. A plugin
// that wants text puts a text field in the page, and WebKit brings up
// the keyboard for it.
int mvmz_isTextInputActive(void) { return 0; }
void mvmz_pushTextInput(const char *utf8) {}

// MARK: - Alerts

void mvmz_presentErrorAndWait(const char *message) {
    if (gErrorMessage.fn) {
        ((mvmz_ErrorMessageCallback)gErrorMessage.fn)(message, gErrorMessage.userdata);
    }
}

void mvmz_presentInfoAndWait(const char *message) {
    if (gInfoMessage.fn) {
        ((mvmz_InfoMessageCallback)gInfoMessage.fn)(message, gInfoMessage.userdata);
    }
}

void mvmz_signalErrorDismissed(void) {}
void mvmz_signalInfoDismissed(void) {}

// MARK: - What the launcher pushes

void mvmz_setDebugLogPath(const char *path) {
    [gLog closeFile];
    gLog = nil;
    if (!path || !path[0]) {
        return;
    }
    gLog = [NSFileHandle fileHandleForWritingAtPath:@(path)];
    [gLog seekToEndOfFile];
    logLine(@"log is attached");
}

// The launcher sends the same overlay it gives mkxp-z. Empo writes
// "smoothScaling" as a number or a boolean.
void mvmz_setConfigOverlayJSON(const char *jsonUTF8) {
    NSDictionary *overlay = nil;
    if (jsonUTF8) {
        overlay = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:jsonUTF8 length:strlen(jsonUTF8)]
                                                  options:0
                                                    error:nil];
    }
    if (![overlay isKindOfClass:NSDictionary.class]) {
        overlay = @{};
    }
    id smooth = overlay[@"smoothScaling"];
    gSmoothScaling = [smooth isKindOfClass:NSNumber.class] ? [smooth boolValue] : NO;
}

void mvmz_setFastForwardMultiplier(int multiplier) {
    gFastForward = multiplier;
    runJS([NSString stringWithFormat:@"window.__mvmz && __mvmz.setSpeed(%d)", multiplier]);
}

int mvmz_getFastForwardMultiplier(void) { return gFastForward; }

void mvmz_setHostViewportRegion(float x, float y, float w, float h, bool isPortrait) {
    gHostRegion = CGRectMake(x, y, w, h);
    gHostRegionPortrait = isPortrait;
    gHasHostRegion = YES;
    placeWebView();
}

void mvmz_clearHostViewportRegion(void) {
    gHasHostRegion = NO;
    placeWebView();
}

void mvmz_setSafeAreaInsets(float top, float bottom, float left, float right) {
    gSafeArea = UIEdgeInsetsMake(top, left, bottom, right);
    placeWebView();
}

void mvmz_applySessionConfig(const MvmzSessionConfig *config) {
    if (!config) {
        return;
    }
    gVerticalAlignment = config->verticalAlignment;
    placeWebView();
}

MvmzVerticalAlignment mvmz_getVerticalAlignment(void) { return gVerticalAlignment; }

void mvmz_setCheatsEnabled(bool enabled) { gCheatsEnabled = enabled; }
bool mvmz_getCheatsEnabled(void) { return gCheatsEnabled; }

void mvmz_setSetting(const char *key, const char *value) {
    NSLog(@"[mvmz] unknown setting %s", key ?: "(null)");
}

// An MV or MZ game has nothing these could reach.
void mvmz_setLauncherIdentity(const char *name) {}
void mvmz_setCABundlePath(const char *path) {}
void mvmz_setShowViewportBounds(bool enabled) {}
void mvmz_setViewportBoundsColor(float r, float g, float b, float a) {}
void mvmz_setGameControllerCaptureEnabled(bool enabled) {}
void mvmz_setTouchMouseEnabled(bool enabled) {}

// MARK: - What the launcher reads

const char *mvmz_getGameTitle(void) { return ""; }
const char *mvmz_getDetails(void) { return gDetails ? gDetails : ""; }
int mvmz_getTargetFPS(void) { return 60; }

// runtime.js measures the rate once a second. The overlay reads it ten
// times a second, so a count per read would come out 0 nine times.
double mvmz_getAverageFPS(void) { return gFps; }
