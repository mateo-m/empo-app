// PSDK core: the boundary between a host app and a released Pokemon SDK
// game running on LiteRGSS2, LiteCGSS, SFML and Ruby 3.0.
//
// Everything below is the whole interface. The core ships as
// PsdkCore.framework, one dynamic image per SDK, and that image
// boundary is what keeps its Ruby 3.0 and its LiteRGSS classes away
// from the mkxp-z engine. Do not link litergss30-merged.o into a binary
// that holds mkxp-z: `ld -r` cannot demote a common symbol or a
// coalesced weak definition, so the merged object still shares 212 Ruby
// and openssl slots and its ViewportElement vtable with that engine.
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
    PSDK_SUPPORT_MISSING = -6,
};

// Runs the game in gameDir and returns when it stops.
//
// Call this once for each process, and not from the main thread. Ruby's
// `ruby_init` runs once for each process, and SFML marshals its UIKit
// calls to the main thread with dispatch_sync, so the main thread has
// to stay free to answer them.
//
// argc and argv come straight from main. Ruby keeps them and reads
// argv[0] later for its own paths, so a caller that passes 0 and null
// leaves Ruby to fall back on whatever it can find.
//
// supportDir names the core's Ruby support folder, which the
// `psdk-support` make target builds. The core prepends it to $LOAD_PATH
// and points the GAMEDEPS variable at it. PSDK reads GAMEDEPS to find
// its native extensions.
//
// preludePath, when it is not null, names a Ruby file that runs after
// LiteRGSS registers its classes and before Game.rb. Per-game
// compatibility code belongs there, not in this core.
//
// Returns PSDK_OK when the game stopped on its own, or a negative
// PsdkResult.
int psdk_run(int argc, char **argv, const char *gameDir, const char *supportDir,
             const char *preludePath);

// Presses or releases one SFML scancode. Call from any thread.
void psdk_inject_scancode(int scancode, int pressed);

#ifdef __cplusplus
}
#endif

#endif
