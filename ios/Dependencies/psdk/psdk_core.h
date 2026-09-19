// PSDK core: the boundary between a host app and a released Pokemon SDK
// game running on LiteRGSS2, LiteCGSS, SFML and Ruby 3.0.
//
// Everything below is the whole interface. The core links as one
// relocatable object, `litergss30-merged.o`, which hides every Ruby and
// LiteRGSS symbol so it cannot clash with the mkxp-z engine's three
// Rubys in the same binary.
#ifndef PSDK_CORE_H
#define PSDK_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

enum PsdkResult {
    PSDK_OK = 0,
    PSDK_RUBY_BOOT_FAILED = -1,
    PSDK_LITERGSS_MISSING = -2,
    PSDK_CHDIR_FAILED = -3,
    PSDK_PRELUDE_RAISED = -4,
    PSDK_GAME_RAISED = -5,
};

// Runs the game in gameDir and returns when it stops.
//
// Call this once for each process, and not from the main thread. Ruby's
// `ruby_init` runs once for each process, and SFML marshals its UIKit
// calls to the main thread with dispatch_sync, so the main thread has
// to stay free to answer them.
//
// preludePath, when it is not null, names a Ruby file that runs after
// LiteRGSS registers its classes and before Game.rb. Per-game
// compatibility code belongs there, not in this core.
//
// Returns PSDK_OK when the game stopped on its own, or a negative
// PsdkResult.
int psdk_run(const char *gameDir, const char *preludePath);

// Presses or releases one SFML scancode. Call from any thread.
void psdk_inject_scancode(int scancode, int pressed);

#ifdef __cplusplus
}
#endif

#endif
