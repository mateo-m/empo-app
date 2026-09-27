// PSDK core: the boundary between a host app and a released Pokemon SDK
// game running on LiteRGSS2, LiteCGSS, SFML and one Ruby.
//
// Everything below is the whole interface. The core ships as one
// framework for each Ruby, Psdk25Core to Psdk33Core, and that image
// boundary is what keeps its Ruby and its LiteRGSS classes away from
// the mkxp-z engine.
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
// supportDir names the Ruby support folder of that Ruby, which the
// `psdk<NN>-support` make target builds. The core prepends it to $LOAD_PATH
// and points the GAMEDEPS variable at it. PSDK reads GAMEDEPS to find
// its native extensions.
//
// preludePath, when it is not null, names a Ruby file that runs after
// LiteRGSS registers its classes and before Game.rb. Per-game
// compatibility code belongs there, not in this core.
//
// The game runs on the Ruby that the "rubyVersion" setting names
// (psdk_setSetting): "2.5", "3.0", "3.2" or "3.3". Without the setting,
// it runs on 3.0.
//
// Returns PSDK_OK when the game stopped on its own, or a negative
// PsdkResult.
int psdk_run(int argc, char **argv, const char *gameDir, const char *supportDir,
             const char *preludePath);

// The Ruby of the core. Each Ruby's merged object exports its entry
// below and no other name.
typedef struct PsdkRuby {
    // RUBY_VERSION of this Ruby, such as "2.5.9".
    const char *version;
    int (*run)(int argc, char **argv, const char *gameDir, const char *supportDir,
               const char *preludePath);
} PsdkRuby;

const PsdkRuby *psdk_ruby_25(void);
const PsdkRuby *psdk_ruby_30(void);
const PsdkRuby *psdk_ruby_32(void);
const PsdkRuby *psdk_ruby_33(void);

// Presses or releases one SFML scancode. Call from any thread.
void psdk_inject_scancode(int scancode, int pressed);

#ifdef __cplusplus
}
#endif

#endif
