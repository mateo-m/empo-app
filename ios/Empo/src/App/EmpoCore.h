// Opening a game core.
//
// Empo links no engine. It opens a core when the user picks a game, and
// the core decides which engine, which Ruby and which classes that game
// runs on. A core that is never picked is never loaded.
//
// GameCoreForwarders.c implements this. Every gamecore_* call in the
// app goes through a forwarder that reads the same name from the open
// core.

#ifndef EMPO_CORE_H
#define EMPO_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Opens the core at binaryPath, which is the Mach-O file inside the
// framework bundle, not the bundle. Returns 1 on success and 0 when
// dlopen fails, after it writes the reason to stderr. A second call for
// the open core succeeds and changes nothing. A call for any other core
// returns 0 until EmpoCoreKillSession ran, because two engines that both
// hold a game share the working directory, the signal handlers, the
// audio device and the main thread.
int EmpoCoreOpen(const char *binaryPath);

int EmpoCoreIsOpen(void);

// Calls gamecore_killSession on the open core, then lets EmpoCoreOpen
// open a different one.
void EmpoCoreKillSession(void);

// Runs the engine and returns when the game ends. main.m implements
// this, because it holds argc and argv.
//
// Call it from a run loop callout on the main thread, and never from a
// block on the main dispatch queue. The engine holds the thread for the
// whole session, so a main queue block would stop that queue from
// draining, and a core that dispatch_syncs to it deadlocks.
int EmpoCoreRunEngine(void);

#ifdef __cplusplus
}
#endif

#endif
