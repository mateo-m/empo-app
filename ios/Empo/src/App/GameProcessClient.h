// The app side of the game process.
//
// GameProcessClient.m implements a gameprocess_* function for every
// gamecore_* function, and AppCoreForwarders.c calls it while games run
// in a game process. Each call becomes a message to the game process of
// the running game (EmpoGameProcessProtocol.h). A getter answers from
// what the process sent last, and asks it for new values, so no call
// waits for the process.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EmpoGameProcessClient : NSObject

// Starts the session of a new game process that runs the core
// `framework`. The gamecore_* calls wait, in order, until the process
// connects.
+ (void)beginWithFramework:(NSString *)framework;

// Gives the session the connection to its process, and sends the calls
// that waited.
+ (void)attachConnection:(NSXPCConnection *)connection;

// Ends the process of the session. `exited` runs once the process is
// gone, on any thread.
+ (void)endWithExit:(void (^)(void))exited;

// Gets a line for the session log each time the game process does
// something the app did not ask for. Runs on any thread.
+ (void)setEventHandler:(void (^)(NSString *text))handler;

// The memory footprint of the game process in bytes, from its last
// status. 0 when no status came yet.
+ (uint64_t)memoryFootprint;

// The process of the session went away, or never started. A session
// that did not end reports it as a game that stopped.
+ (void)processLost;

@end

NS_ASSUME_NONNULL_END
