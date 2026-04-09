// ios_bridge.h — C-linkage bridge between mkxp-z engine and iOS UIKit overlay
#ifndef IOS_BRIDGE_H
#define IOS_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

void        mkxp_setGameReady(void);
int         mkxp_isGameReady(void);
double      mkxp_getAverageFPS(void);
int         mkxp_getRGSSVersion(void);
const char *mkxp_getGameTitle(void);

#ifdef __cplusplus
}
#endif

#endif // IOS_BRIDGE_H
