// Opening a game core.
//
// Empo links no engine. A game runs either in the app, in a core the app
// opens when the user picks the game, or in a game process of its own
// (GameProcessHost.swift). The core decides which engine, which Ruby and
// which classes that game runs on. A core that is never picked is never
// loaded.
//
// AppCoreForwarders.c implements this. Every gamecore_* call in the
// app goes through a forwarder. The forwarder sends the call to the
// game process (GameProcessClient.m), or reads the same name from the
// core the app opened.

#ifndef EMPO_APP_CORE_H
#define EMPO_APP_CORE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Picks where the gamecore_* calls of the next game go: the game
// process, or the core the app opened. Call it before the game opens,
// and never while a game runs.
void EmpoCoreUseGameProcess(bool use);

// Opens the core at binaryPath in the app, which is the Mach-O file
// inside the framework bundle, not the bundle. Returns 1 on success and
// 0 when dlopen fails, after it writes the reason to stderr. A second
// call for the open core succeeds and changes nothing. A call for any
// other core returns 0 until EmpoCoreKillSession ran, because two
// engines that both hold a game share the working directory, the
// signal handlers, the audio device and the main thread.
int EmpoCoreOpen(const char *binaryPath);

// True when a game process runs, after EmpoCoreUseGameProcess(true).
// Else true once the app opened a core.
int EmpoCoreIsOpen(void);

// True from the start of a game process session to its end.
// GameProcessClient.m implements this.
int EmpoGameProcessIsOpen(void);

// Calls gamecore_killSession on the core the app opened, then lets
// EmpoCoreOpen open a different one.
void EmpoCoreKillSession(void);

// Runs the engine in the app and returns when the game ends. main.m
// implements this, because it holds argc and argv.
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
