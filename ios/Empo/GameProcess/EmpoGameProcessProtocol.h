// The messages between Empo and its game process.
//
// Empo runs each game in a new GameProcess extension process, so that
// quitting a game ends every thread, global and Ruby VM of that game.
// The app side (GameProcessClient.m) turns each gamecore_* call into a
// message of EmpoGameProcess. The game process runs it with the
// gamecore_* call of the same name, in the order the app sent it.

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

NS_ASSUME_NONNULL_BEGIN

// App -> game process.
@protocol EmpoGameProcess

// A block of the app's memory, with the keys EmpoGameProcessMemory*
// below. The app sends it before openCore.
- (void)useMemory:(xpc_object_t)memory;

// Opens the core `framework` from the app's Frameworks folder. The
// reply is nil on success, or the reason.
- (void)openCore:(NSString *)framework reply:(void (^)(NSString *_Nullable error))reply;

- (void)setGamePath:(NSString *)path;
// gamecore_run_app with the process arguments.
- (void)runApp;
- (void)injectKeyEvent:(int)scancode pressed:(int)pressed;
- (void)setLauncherIdentity:(nullable NSString *)name;
- (void)setCABundlePath:(nullable NSString *)path;
- (void)pushTextInput:(NSString *)text;
- (void)setSafeAreaInsetsTop:(float)top bottom:(float)bottom left:(float)left right:(float)right;
- (void)setHostViewportRegionX:(float)x y:(float)y width:(float)width height:(float)height portrait:(BOOL)portrait;
- (void)clearHostViewportRegion;
- (void)applySessionConfigUserData:(nullable NSString *)userDataDirectory
                             fonts:(nullable NSString *)sharedFontsDirectory
                 verticalAlignment:(int)verticalAlignment;
- (void)setSetting:(NSString *)key value:(NSString *)value;
- (void)setShowViewportBounds:(BOOL)enabled;
- (void)setViewportBoundsColorRed:(float)red green:(float)green blue:(float)blue alpha:(float)alpha;
- (void)setCheatsEnabled:(BOOL)enabled;
- (void)setGameControllerCaptureEnabled:(BOOL)enabled;
- (void)setTouchMouseEnabled:(BOOL)enabled;
- (void)signalErrorDismissed;
- (void)signalInfoDismissed;
- (void)requestPause;
- (void)requestResume;
- (void)setFastForwardMultiplier:(int)multiplier;
- (void)resetSessionState;
- (void)setDebugLogPath:(nullable NSString *)path;

// The answers of the gamecore_* getters. The keys are in
// EmpoGameProcessStatus* below.
- (void)fetchStatus:(void (^)(NSDictionary<NSString *, id> *status))reply;

// Ends the process at once.
- (void)quit;

@end

// Game process -> app. Each one is a gamecore_* callback.
@protocol EmpoGameProcessHost

- (void)engineTerminatedCleanly:(BOOL)clean hung:(BOOL)hung;
- (void)gameRectChangedX:(float)x y:(float)y width:(float)width height:(float)height;
- (void)textInputModeChanged:(BOOL)active;
- (void)errorMessage:(NSString *)message;
- (void)infoMessage:(NSString *)message;
// The snapshot is RGBA, width * height * 4 bytes, or nil.
- (void)pausedWithSnapshot:(nullable NSData *)rgba width:(int)width height:(int)height;
- (void)resumed;
- (void)frameRendered;
// iOS sends the hardware keys to the process that the player touched
// last. After a tap on the game, that is the game process, and it sends
// each key on with this message.
- (void)keyChanged:(NSInteger)keyCode pressed:(BOOL)pressed;

@end

static NSString *const EmpoGameProcessStatusGameReady = @"gameReady";
static NSString *const EmpoGameProcessStatusAverageFPS = @"averageFPS";
static NSString *const EmpoGameProcessStatusTargetFPS = @"targetFPS";
static NSString *const EmpoGameProcessStatusTitle = @"title";
static NSString *const EmpoGameProcessStatusDetails = @"details";
static NSString *const EmpoGameProcessStatusCheats = @"cheats";
static NSString *const EmpoGameProcessStatusFastForward = @"fastForward";
// iOS gives the game process a limit of about 300 MB, and kills it at
// that limit. A game can need more: Infinite Fusion asks for 227 MB in
// one call when it starts. iOS counts the pages of a purgeable memory
// entry against the task that made it, also when another process
// writes them. So the app makes the entry, and the game process puts
// its memory in it.
static const char *const EmpoGameProcessMemoryEntry = "entry";
static const char *const EmpoGameProcessMemorySize = "size";

// The phys_footprint of the game process, in bytes.
static NSString *const EmpoGameProcessStatusMemoryFootprint = @"memoryFootprint";

NSXPCInterface *EmpoGameProcessInterface(void);

NS_ASSUME_NONNULL_END
