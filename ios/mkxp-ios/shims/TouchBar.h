/* TouchBar.h stub for iOS - Touch Bar is macOS only */
#ifndef TOUCHBAR_H_STUB
#define TOUCHBAR_H_STUB

#include <SDL.h>

class Config;

static inline void initTouchBar(SDL_Window *win, Config &conf) {
    (void)win; (void)conf;
}

static inline void updateTouchBarFPSDisplay(uint32_t value) {
    (void)value;
}

#endif
