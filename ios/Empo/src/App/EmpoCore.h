// Opening a game core.
//
// Empo links no engine. It opens one core when the user picks a game,
// and the core decides which engine, which Ruby and which classes that
// game runs on. A core that is never picked is never loaded, so two
// cores never share a definition.
//
// MkxpCoreForwarders.c implements this for MkxpCore.framework. Every
// mkxp_* call in the app goes through a forwarder that reads its symbol
// from the open core.

#ifndef EMPO_CORE_H
#define EMPO_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Opens the core at binaryPath, which is the Mach-O file inside the
// framework bundle, not the bundle. Returns 1 on success and 0 when
// dlopen fails, after it writes the reason to stderr. A second call
// with the core already open succeeds and changes nothing.
int EmpoCoreOpen(const char *binaryPath);

int EmpoCoreIsOpen(void);

// Runs the engine and returns when the game ends. main.m implements
// this, because it holds argc and argv.
//
// Call it from a run loop callout on the main thread, and never from a
// block on the main dispatch queue. The engine holds the thread for the
// whole session, so a main queue block would stop that queue from
// draining, and the engine's RGSS thread deadlocks on the first
// mkxp_getScreenScale, which dispatch_syncs to that queue.
int EmpoCoreRunEngine(void);

#ifdef __cplusplus
}
#endif

#endif
