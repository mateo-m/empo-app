#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Serves the app's connection to this game process. Returns NO when a
// connection came already: a game process serves one game.
BOOL EmpoGameProcessAccept(NSXPCConnection *connection);

// The scene of this process has its size. Runs on the main thread.
void EmpoGameProcessSceneHasSize(void);

NS_ASSUME_NONNULL_END
