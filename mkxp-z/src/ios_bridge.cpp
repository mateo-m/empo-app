// ios_bridge.cpp — Minimal C bridge for iOS overlay to query engine state.
// Kept separate from engine code. No UIKit imports. No game logic.

#include "ios_bridge.h"
#include "sharedstate.h"
#include "graphics.h"
#include "eventthread.h"
#include "config.h"
#include <atomic>

static std::atomic<bool> s_gameReady{false};

extern "C" {

void mkxp_setGameReady(void) {
    s_gameReady.store(true, std::memory_order_release);
}

int mkxp_isGameReady(void) {
    return s_gameReady.load(std::memory_order_acquire) ? 1 : 0;
}

double mkxp_getAverageFPS(void) {
    if (!SharedState::instance) return 0.0;
    return SharedState::instance->graphics().averageFrameRate();
}

int mkxp_getRGSSVersion(void) {
    if (!SharedState::instance) return 0;
    return SharedState::instance->rtData().config.rgssVersion;
}

const char *mkxp_getGameTitle(void) {
    if (!SharedState::instance) return "";
    return SharedState::instance->rtData().config.game.title.c_str();
}

} // extern "C"
