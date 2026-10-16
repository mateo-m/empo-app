// Opening the game core in the game process.
//
// GameCoreForwarders.c implements this. Every gamecore_* call in the
// game process goes through a forwarder that reads the same name from
// the open core.

#ifndef EMPO_CORE_H
#define EMPO_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Opens the core at binaryPath, which is the Mach-O file inside the
// framework bundle, not the bundle. Returns 1 on success, and 0 when
// dlopen fails, after it writes the reason to stderr. A game process
// opens one core.
int EmpoCoreOpen(const char *binaryPath);

#ifdef __cplusplus
}
#endif

#endif
