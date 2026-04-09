// ios_bridge.h — C-linkage bridge between mkxp-z engine and iOS UIKit overlay
#ifndef IOS_BRIDGE_H
#define IOS_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// Game lifecycle
void        mkxp_setGameReady(void);
int         mkxp_isGameReady(void);

// Game selection (Library -> Engine)
// mkxp_setGamePath: called by the Library when the user picks a game.
// mkxp_waitForGamePath: blocks until mkxp_setGamePath is called, returns the path.
void        mkxp_setGamePath(const char *path);
const char *mkxp_waitForGamePath(void);

// Engine termination
// mkxp_requestTerminate: UI asks the engine to shut down (pushes SDL_QUIT).
// mkxp_isEngineTerminated: UI polls to know when the engine has fully shut down.
// mkxp_setEngineTerminated: engine sets this after teardown is complete.
// mkxp_resetBridgeState: resets all bridge flags for a new game session.
void        mkxp_requestTerminate(void);
int         mkxp_isEngineTerminated(void);
void        mkxp_setEngineTerminated(void);
void        mkxp_resetBridgeState(void);

// Engine state queries
double      mkxp_getAverageFPS(void);
int         mkxp_getRGSSVersion(void);
const char *mkxp_getGameTitle(void);

// Game viewport rect in logical points (for touch controls positioning).
// mkxp_setGameRect: called by the engine when viewport changes.
// mkxp_getGameRect: called by the UI to read the current game area.
void        mkxp_setGameRect(float x, float y, float w, float h);
void        mkxp_getGameRect(float *x, float *y, float *w, float *h);

// Safe area insets in logical points.
// mkxp_getSafeAreaInsets: returns top, bottom, left, right insets.
void        mkxp_getSafeAreaInsets(float *top, float *bottom, float *left, float *right);

// UIKit screen scale factor (e.g. 3.0 on iPhone Pro).
// Use this instead of SDL's backingScaleFactor when converting UIKit points to GL pixels.
float       mkxp_getScreenScale(void);

#ifdef __cplusplus
}
#endif

#endif // IOS_BRIDGE_H
