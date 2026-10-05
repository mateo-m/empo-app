#import "GameProcessClient.h"

#import <os/lock.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <stdlib.h>
#include <string.h>

#import "EmpoAppCore.h"
#import "EmpoGameProcessProtocol.h"
#include "GameCore.h"

typedef void (^Call)(id<EmpoGameProcess> process);

// Every static below is read and written under this lock. The app
// calls in on the main thread, and the process answers on the
// connection's queue.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

// The session runs from begin to end.
static BOOL gOpen;
static NSXPCConnection *gConnection;
static NSMutableArray<Call> *gWaiting;

// The process of the last session that ended, until it is gone.
static void *gExitingToken;
static void (^gExited)(void);

// What the process said last.
static NSDictionary<NSString *, id> *gStatus;
static BOOL gStatusAsked;
static BOOL gTextInputActive;
static BOOL gPaused;
static BOOL gTerminated;
static BOOL gExitedCleanly;
static BOOL gHung;
static GameCoreVerticalAlignment gVerticalAlignment;
static NSData *gSnapshot;
static int gSnapshotWidth;
static int gSnapshotHeight;

static gamecore_EngineTerminatedCallback gTerminatedCallback;
static void *gTerminatedUserdata;
static gamecore_GameRectChangedCallback gRectCallback;
static void *gRectUserdata;
static gamecore_TextInputModeCallback gTextInputCallback;
static void *gTextInputUserdata;
static gamecore_ErrorMessageCallback gErrorCallback;
static void *gErrorUserdata;
static gamecore_InfoMessageCallback gInfoCallback;
static void *gInfoUserdata;
static gamecore_PausedCallback gPausedCallback;
static void *gPausedUserdata;
static gamecore_ResumedCallback gResumedCallback;
static void *gResumedUserdata;
static gamecore_FrameRenderedCallback gFrameCallback;
static void *gFrameUserdata;

static void (^gEventHandler)(NSString *);

// Logs what happened to the game process, and gives it to the app for
// the session log.
static void noteEvent(NSString *text) {
    NSLog(@"[game-process] %@", text);
    void (^handler)(NSString *) = gEventHandler;
    if (handler != nil) {
        handler(text);
    }
}

static id<EmpoGameProcess> proxyOf(NSXPCConnection *connection) {
    return [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"[game-process] message failed: %@", error);
    }];
}

// Sends the call now, or keeps it for the process that did not connect
// yet. A call outside a session goes nowhere.
static void send(Call call) {
    os_unfair_lock_lock(&gLock);
    if (gConnection != nil) {
        call(proxyOf(gConnection));
    } else if (gOpen) {
        [gWaiting addObject:call];
    }
    os_unfair_lock_unlock(&gLock);
}

// Under the lock. The getters answer from the last status, so the
// values lag one call behind.
static void askForStatus(void) {
    if (gStatusAsked || gConnection == nil) {
        return;
    }
    gStatusAsked = YES;
    void *token = (__bridge void *)gConnection;
    [proxyOf(gConnection) fetchStatus:^(NSDictionary<NSString *, id> *status) {
        os_unfair_lock_lock(&gLock);
        if ((__bridge void *)gConnection == token) {
            gStatus = status;
            gStatusAsked = NO;
        }
        os_unfair_lock_unlock(&gLock);
    }];
}

static id statusValue(NSString *key) {
    os_unfair_lock_lock(&gLock);
    askForStatus();
    id value = gStatus[key];
    os_unfair_lock_unlock(&gLock);
    return value;
}

// Under the lock. A setter changes the value now, so a getter right
// after it does not answer with the old one.
static void setStatusValue(NSString *key, id value) {
    NSMutableDictionary<NSString *, id> *status = [gStatus mutableCopy];
    status[key] = value;
    gStatus = status;
}

// The session lost its process without an end: the game stopped.
// Under the lock. Returns the callback to call after the unlock.
static gamecore_EngineTerminatedCallback loseProcess(void **userdata) {
    gConnection = nil;
    [gWaiting removeAllObjects];
    if (!gOpen || gTerminated) {
        return NULL;
    }
    gTerminated = YES;
    gExitedCleanly = NO;
    *userdata = gTerminatedUserdata;
    return gTerminatedCallback;
}

static void connectionEnded(void *token) {
    void (^exited)(void) = nil;
    gamecore_EngineTerminatedCallback terminated = NULL;
    void *userdata = NULL;
    os_unfair_lock_lock(&gLock);
    if (token == gExitingToken) {
        exited = gExited;
        gExited = nil;
        gExitingToken = NULL;
    } else if (token == (__bridge void *)gConnection) {
        noteEvent(@"The game process went away.");
        terminated = loseProcess(&userdata);
    }
    os_unfair_lock_unlock(&gLock);
    if (exited != nil) {
        exited();
    }
    if (terminated != NULL) {
        terminated(userdata);
    }
}

// Runs `body` under the lock when the message came from the process of
// the open session. A message from a process that ended is late.
static BOOL fromSession(NSXPCConnection *connection, void (^body)(void)) {
    os_unfair_lock_lock(&gLock);
    BOOL current = gOpen && connection != nil && connection == gConnection;
    if (current) {
        body();
    }
    os_unfair_lock_unlock(&gLock);
    return current;
}

@interface EmpoGameProcessHostReceiver : NSObject <EmpoGameProcessHost>
@property (nonatomic, weak) NSXPCConnection *connection;
@end

@implementation EmpoGameProcessHostReceiver

- (void)engineTerminatedCleanly:(BOOL)clean hung:(BOOL)hung {
    __block gamecore_EngineTerminatedCallback callback = NULL;
    __block void *userdata = NULL;
    fromSession(self.connection, ^{
        gTerminated = YES;
        gExitedCleanly = clean;
        gHung = hung;
        callback = gTerminatedCallback;
        userdata = gTerminatedUserdata;
    });
    if (callback != NULL) {
        callback(userdata);
    }
}

- (void)gameRectChangedX:(float)x y:(float)y width:(float)width height:(float)height {
    __block gamecore_GameRectChangedCallback callback = NULL;
    __block void *userdata = NULL;
    fromSession(self.connection, ^{
        callback = gRectCallback;
        userdata = gRectUserdata;
    });
    if (callback != NULL) {
        callback(x, y, width, height, userdata);
    }
}

- (void)textInputModeChanged:(BOOL)active {
    __block gamecore_TextInputModeCallback callback = NULL;
    __block void *userdata = NULL;
    fromSession(self.connection, ^{
        gTextInputActive = active;
        callback = gTextInputCallback;
        userdata = gTextInputUserdata;
    });
    // GameCore.h fires this one on the main thread.
    if (callback != NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{ callback(active, userdata); });
    }
}

- (void)errorMessage:(NSString *)message {
    __block gamecore_ErrorMessageCallback callback = NULL;
    __block void *userdata = NULL;
    fromSession(self.connection, ^{
        callback = gErrorCallback;
        userdata = gErrorUserdata;
    });
    if (callback != NULL) {
        callback(message.UTF8String, userdata);
    }
}

- (void)infoMessage:(NSString *)message {
    __block gamecore_InfoMessageCallback callback = NULL;
    __block void *userdata = NULL;
    fromSession(self.connection, ^{
        callback = gInfoCallback;
        userdata = gInfoUserdata;
    });
    if (callback != NULL) {
        callback(message.UTF8String, userdata);
    }
}

- (void)pausedWithSnapshot:(NSData *)rgba width:(int)width height:(int)height {
    __block gamecore_PausedCallback callback = NULL;
    __block void *userdata = NULL;
    fromSession(self.connection, ^{
        gPaused = YES;
        gSnapshot = rgba;
        gSnapshotWidth = width;
        gSnapshotHeight = height;
        callback = gPausedCallback;
        userdata = gPausedUserdata;
    });
    if (callback != NULL) {
        callback(userdata);
    }
}

- (void)resumed {
    __block gamecore_ResumedCallback callback = NULL;
    __block void *userdata = NULL;
    fromSession(self.connection, ^{
        gPaused = NO;
        callback = gResumedCallback;
        userdata = gResumedUserdata;
    });
    if (callback != NULL) {
        callback(userdata);
    }
}

- (void)frameRendered {
    __block gamecore_FrameRenderedCallback callback = NULL;
    __block void *userdata = NULL;
    fromSession(self.connection, ^{
        callback = gFrameCallback;
        userdata = gFrameUserdata;
    });
    if (callback != NULL) {
        callback(userdata);
    }
}

@end

@implementation EmpoGameProcessClient

// A new block for each game, 3/4 of what the app can still get, so that
// a game that fills it does not stop the app. iOS counts the block in the
// app's own use. The simulator has no limit, and reports 0.
static xpc_object_t lentMemory(void) {
    size_t available = os_proc_available_memory();
    if (available == 0) {
        return nil;
    }
    memory_object_size_t size = available / 4 * 3;
    mach_port_t entry = MACH_PORT_NULL;
    kern_return_t made = mach_make_memory_entry_64(
        mach_task_self(), &size, 0, MAP_MEM_NAMED_CREATE | MAP_MEM_PURGABLE | VM_PROT_READ | VM_PROT_WRITE,
        &entry, MACH_PORT_NULL);
    if (made != KERN_SUCCESS) {
        NSLog(@"[game-process] cannot make a memory entry: %s", mach_error_string(made));
        return nil;
    }
    xpc_object_t memory = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_mach_send(memory, EmpoGameProcessMemoryEntry, entry);
    xpc_dictionary_set_uint64(memory, EmpoGameProcessMemorySize, size);
    // The dictionary holds its own send right. iOS frees the memory
    // when the game process ends.
    mach_port_deallocate(mach_task_self(), entry);
    return memory;
}

+ (void)beginWithFramework:(NSString *)framework {
    os_unfair_lock_lock(&gLock);
    NSAssert(!gOpen, @"a game process session is open");
    gOpen = YES;
    gConnection = nil;
    gWaiting = [NSMutableArray new];
    gStatus = @{};
    gStatusAsked = NO;
    gTextInputActive = NO;
    gPaused = NO;
    gTerminated = NO;
    gExitedCleanly = NO;
    gHung = NO;
    gVerticalAlignment = GAMECORE_VALIGN_TOP;
    gSnapshot = nil;
    gSnapshotWidth = 0;
    gSnapshotHeight = 0;
    os_unfair_lock_unlock(&gLock);
    xpc_object_t memory = lentMemory();
    send(^(id<EmpoGameProcess> process) {
        if (memory != nil) {
            [process useMemory:memory];
        }
        // A late reply can come after a new session began, so it ends
        // only the connection that sent it.
        __weak NSXPCConnection *weakConnection = gConnection;
        [process openCore:framework
                    reply:^(NSString *error) {
                        NSXPCConnection *connection = weakConnection;
                        if (error == nil || connection == nil) {
                            return;
                        }
                        noteEvent([NSString
                            stringWithFormat:@"The game process could not open the core: %@", error]);
                        [connection invalidate];
                        connectionEnded((__bridge void *)connection);
                    }];
    });
}

+ (void)attachConnection:(NSXPCConnection *)connection {
    EmpoGameProcessHostReceiver *receiver = [EmpoGameProcessHostReceiver new];
    receiver.connection = connection;
    connection.remoteObjectInterface = EmpoGameProcessInterface();
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(EmpoGameProcessHost)];
    connection.exportedObject = receiver;
    // A pointer to compare, never to follow: the handlers can run after
    // the connection is gone.
    void *token = (__bridge void *)connection;
    connection.interruptionHandler = ^{ connectionEnded(token); };
    connection.invalidationHandler = ^{ connectionEnded(token); };
    [connection resume];

    os_unfair_lock_lock(&gLock);
    BOOL wanted = gOpen && gConnection == nil && !gTerminated;
    if (wanted) {
        gConnection = connection;
        id<EmpoGameProcess> process = proxyOf(connection);
        for (Call call in gWaiting) {
            call(process);
        }
        [gWaiting removeAllObjects];
    }
    os_unfair_lock_unlock(&gLock);
    if (!wanted) {
        [connection invalidate];
    }
}

+ (void)endWithExit:(void (^)(void))exited {
    os_unfair_lock_lock(&gLock);
    NSXPCConnection *connection = gConnection;
    gOpen = NO;
    gConnection = nil;
    [gWaiting removeAllObjects];
    if (connection != nil) {
        gExitingToken = (__bridge void *)connection;
        gExited = [exited copy];
        [proxyOf(connection) quit];
    }
    os_unfair_lock_unlock(&gLock);
    if (connection == nil) {
        exited();
        return;
    }
    // The guard for a process that never goes away. It quits at once
    // on the message, and the connection ends a moment later.
    void *token = (__bridge void *)connection;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        os_unfair_lock_lock(&gLock);
        BOOL waiting = gExitingToken == token;
        os_unfair_lock_unlock(&gLock);
        if (waiting) {
            noteEvent(@"The game process did not end in time, and Empo closed its connection.");
            [connection invalidate];
            connectionEnded(token);
        }
    });
}

+ (void)setEventHandler:(void (^)(NSString *))handler {
    gEventHandler = [handler copy];
}

+ (uint64_t)memoryFootprint {
    return [statusValue(EmpoGameProcessStatusMemoryFootprint) unsignedLongLongValue];
}

+ (void)processLost {
    void *userdata = NULL;
    os_unfair_lock_lock(&gLock);
    NSXPCConnection *connection = gConnection;
    gamecore_EngineTerminatedCallback terminated = loseProcess(&userdata);
    os_unfair_lock_unlock(&gLock);
    [connection invalidate];
    if (terminated != NULL) {
        terminated(userdata);
    }
}

@end

int EmpoGameProcessIsOpen(void) {
    os_unfair_lock_lock(&gLock);
    BOOL open = gOpen;
    os_unfair_lock_unlock(&gLock);
    return open;
}

// MARK: - GameCore.h

// AppCoreForwarders.c sends each gamecore_* call here while games run
// in a game process. Each gameprocess_* function stands for the
// gamecore_* function of the same name.

// The game draws in the window of its own process.
void *gameprocess_getGameWindow(void) {
    return NULL;
}

// The app ends the game process instead (GameProcessHost.end).
void gameprocess_killSession(void) {
}

// The game process runs the core with its own arguments.
int gameprocess_run_app(int argc, char **argv) {
    send(^(id<EmpoGameProcess> process) { [process runApp]; });
    return 0;
}

int gameprocess_isGameReady(void) {
    return [statusValue(EmpoGameProcessStatusGameReady) boolValue];
}

void gameprocess_setGamePath(const char *path) {
    NSString *value = @(path);
    send(^(id<EmpoGameProcess> process) { [process setGamePath:value]; });
}

int gameprocess_isEngineTerminated(void) {
    os_unfair_lock_lock(&gLock);
    BOOL terminated = gTerminated;
    os_unfair_lock_unlock(&gLock);
    return terminated;
}

int gameprocess_didEngineExitCleanly(void) {
    os_unfair_lock_lock(&gLock);
    BOOL clean = gExitedCleanly;
    os_unfair_lock_unlock(&gLock);
    return clean;
}

int gameprocess_isEngineHung(void) {
    os_unfair_lock_lock(&gLock);
    BOOL hung = gHung;
    os_unfair_lock_unlock(&gLock);
    return hung;
}

void gameprocess_setEngineTerminatedCallback(gamecore_EngineTerminatedCallback cb, void *userdata) {
    os_unfair_lock_lock(&gLock);
    gTerminatedCallback = cb;
    gTerminatedUserdata = userdata;
    os_unfair_lock_unlock(&gLock);
}

void gameprocess_setGameRectChangedCallback(gamecore_GameRectChangedCallback cb, void *userdata) {
    os_unfair_lock_lock(&gLock);
    gRectCallback = cb;
    gRectUserdata = userdata;
    os_unfair_lock_unlock(&gLock);
}

void gameprocess_injectKeyEvent(int scancode, int pressed) {
    send(^(id<EmpoGameProcess> process) { [process injectKeyEvent:scancode pressed:pressed]; });
}

void gameprocess_setLauncherIdentity(const char *name) {
    NSString *value = name != NULL ? @(name) : nil;
    send(^(id<EmpoGameProcess> process) { [process setLauncherIdentity:value]; });
}

void gameprocess_setCABundlePath(const char *path) {
    NSString *value = path != NULL ? @(path) : nil;
    send(^(id<EmpoGameProcess> process) { [process setCABundlePath:value]; });
}

void gameprocess_setTextInputModeCallback(gamecore_TextInputModeCallback cb, void *userdata) {
    os_unfair_lock_lock(&gLock);
    gTextInputCallback = cb;
    gTextInputUserdata = userdata;
    os_unfair_lock_unlock(&gLock);
}

void gameprocess_pushTextInput(const char *utf8) {
    NSString *value = @(utf8);
    send(^(id<EmpoGameProcess> process) { [process pushTextInput:value]; });
}

int gameprocess_isTextInputActive(void) {
    os_unfair_lock_lock(&gLock);
    BOOL active = gTextInputActive;
    os_unfair_lock_unlock(&gLock);
    return active;
}

double gameprocess_getAverageFPS(void) {
    return [statusValue(EmpoGameProcessStatusAverageFPS) doubleValue];
}

int gameprocess_getTargetFPS(void) {
    return [statusValue(EmpoGameProcessStatusTargetFPS) intValue];
}

// The text stays valid until the next call, as GameCore.h says.
static const char *keepText(char **slot, NSString *text) {
    free(*slot);
    *slot = strdup(text.UTF8String ?: "");
    return *slot;
}

const char *gameprocess_getGameTitle(void) {
    static char *title;
    return keepText(&title, statusValue(EmpoGameProcessStatusTitle));
}

const char *gameprocess_getDetails(void) {
    static char *details;
    return keepText(&details, statusValue(EmpoGameProcessStatusDetails));
}

void gameprocess_setSafeAreaInsets(float top, float bottom, float left, float right) {
    send(^(id<EmpoGameProcess> process) {
        [process setSafeAreaInsetsTop:top bottom:bottom left:left right:right];
    });
}

void gameprocess_setHostViewportRegion(float x, float y, float w, float h, bool isPortrait) {
    send(^(id<EmpoGameProcess> process) {
        [process setHostViewportRegionX:x y:y width:w height:h portrait:isPortrait];
    });
}

void gameprocess_clearHostViewportRegion(void) {
    send(^(id<EmpoGameProcess> process) { [process clearHostViewportRegion]; });
}

GameCoreVerticalAlignment gameprocess_getVerticalAlignment(void) {
    os_unfair_lock_lock(&gLock);
    GameCoreVerticalAlignment alignment = gVerticalAlignment;
    os_unfair_lock_unlock(&gLock);
    return alignment;
}

void gameprocess_applySessionConfig(const GameCoreSessionConfig *config) {
    NSString *userData = config->userDataDirectory != NULL ? @(config->userDataDirectory) : nil;
    NSString *fonts = config->sharedFontsDirectory != NULL ? @(config->sharedFontsDirectory) : nil;
    GameCoreVerticalAlignment alignment = config->verticalAlignment;
    os_unfair_lock_lock(&gLock);
    gVerticalAlignment = alignment;
    os_unfair_lock_unlock(&gLock);
    send(^(id<EmpoGameProcess> process) {
        [process applySessionConfigUserData:userData fonts:fonts verticalAlignment:alignment];
    });
}

void gameprocess_setSetting(const char *key, const char *value) {
    NSString *keyText = @(key);
    NSString *valueText = @(value);
    send(^(id<EmpoGameProcess> process) { [process setSetting:keyText value:valueText]; });
}

void gameprocess_setShowViewportBounds(bool enabled) {
    send(^(id<EmpoGameProcess> process) { [process setShowViewportBounds:enabled]; });
}

void gameprocess_setCheatsEnabled(bool enabled) {
    os_unfair_lock_lock(&gLock);
    setStatusValue(EmpoGameProcessStatusCheats, @(enabled));
    os_unfair_lock_unlock(&gLock);
    send(^(id<EmpoGameProcess> process) { [process setCheatsEnabled:enabled]; });
}

bool gameprocess_getCheatsEnabled(void) {
    return [statusValue(EmpoGameProcessStatusCheats) boolValue];
}

void gameprocess_setGameControllerCaptureEnabled(bool enabled) {
    send(^(id<EmpoGameProcess> process) { [process setGameControllerCaptureEnabled:enabled]; });
}

void gameprocess_setTouchMouseEnabled(bool enabled) {
    send(^(id<EmpoGameProcess> process) { [process setTouchMouseEnabled:enabled]; });
}

void gameprocess_setViewportBoundsColor(float r, float g, float b, float a) {
    send(^(id<EmpoGameProcess> process) { [process setViewportBoundsColorRed:r green:g blue:b alpha:a]; });
}

void gameprocess_signalErrorDismissed(void) {
    send(^(id<EmpoGameProcess> process) { [process signalErrorDismissed]; });
}

void gameprocess_setErrorMessageCallback(gamecore_ErrorMessageCallback cb, void *userdata) {
    os_unfair_lock_lock(&gLock);
    gErrorCallback = cb;
    gErrorUserdata = userdata;
    os_unfair_lock_unlock(&gLock);
}

void gameprocess_signalInfoDismissed(void) {
    send(^(id<EmpoGameProcess> process) { [process signalInfoDismissed]; });
}

void gameprocess_setInfoMessageCallback(gamecore_InfoMessageCallback cb, void *userdata) {
    os_unfair_lock_lock(&gLock);
    gInfoCallback = cb;
    gInfoUserdata = userdata;
    os_unfair_lock_unlock(&gLock);
}

void gameprocess_requestPause(void) {
    send(^(id<EmpoGameProcess> process) { [process requestPause]; });
}

void gameprocess_requestResume(void) {
    send(^(id<EmpoGameProcess> process) { [process requestResume]; });
}

bool gameprocess_isPaused(void) {
    os_unfair_lock_lock(&gLock);
    BOOL paused = gPaused;
    os_unfair_lock_unlock(&gLock);
    return paused;
}

bool gameprocess_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height) {
    os_unfair_lock_lock(&gLock);
    NSData *snapshot = gSnapshot;
    *width = gSnapshotWidth;
    *height = gSnapshotHeight;
    os_unfair_lock_unlock(&gLock);
    if (snapshot == nil || (NSUInteger)destSize < snapshot.length) {
        return false;
    }
    memcpy(dest, snapshot.bytes, snapshot.length);
    return true;
}

bool gameprocess_getSnapshotSize(int *width, int *height) {
    os_unfair_lock_lock(&gLock);
    BOOL available = gSnapshot != nil;
    *width = gSnapshotWidth;
    *height = gSnapshotHeight;
    os_unfair_lock_unlock(&gLock);
    return available;
}

void gameprocess_setPausedCallback(gamecore_PausedCallback cb, void *userdata) {
    os_unfair_lock_lock(&gLock);
    gPausedCallback = cb;
    gPausedUserdata = userdata;
    os_unfair_lock_unlock(&gLock);
}

void gameprocess_setResumedCallback(gamecore_ResumedCallback cb, void *userdata) {
    os_unfair_lock_lock(&gLock);
    gResumedCallback = cb;
    gResumedUserdata = userdata;
    os_unfair_lock_unlock(&gLock);
}

void gameprocess_setFrameRenderedCallback(gamecore_FrameRenderedCallback cb, void *userdata) {
    os_unfair_lock_lock(&gLock);
    gFrameCallback = cb;
    gFrameUserdata = userdata;
    os_unfair_lock_unlock(&gLock);
}

void gameprocess_setFastForwardMultiplier(int multiplier) {
    os_unfair_lock_lock(&gLock);
    setStatusValue(EmpoGameProcessStatusFastForward, @(multiplier));
    os_unfair_lock_unlock(&gLock);
    send(^(id<EmpoGameProcess> process) { [process setFastForwardMultiplier:multiplier]; });
}

int gameprocess_getFastForwardMultiplier(void) {
    NSNumber *multiplier = statusValue(EmpoGameProcessStatusFastForward);
    return multiplier != nil ? multiplier.intValue : 1;
}

void gameprocess_resetSessionState(void) {
    send(^(id<EmpoGameProcess> process) { [process resetSessionState]; });
}

void gameprocess_setDebugLogPath(const char *path) {
    NSString *value = path != NULL && path[0] != '\0' ? @(path) : nil;
    send(^(id<EmpoGameProcess> process) { [process setDebugLogPath:value]; });
}
