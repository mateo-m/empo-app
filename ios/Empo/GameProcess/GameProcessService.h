#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Serves the app's connection to this game process. Returns NO when a
// connection came already: a game process serves one game.
BOOL EmpoGameProcessAccept(NSXPCConnection *connection);

NS_ASSUME_NONNULL_END
