// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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

// Lets silent mode mute the game, in the process that plays
// it. Call it after the game opens, and again when the setting changes.
void EmpoCoreSetRespectsSilentMode(bool respects);

// GameProcessClient.m implements this.
void EmpoGameProcessSetRespectsSilentMode(bool respects);

// Calls gamecore_killSession on the core the app opened, then lets
// EmpoCoreOpen open a different one.
void EmpoCoreKillSession(void);

#ifdef __cplusplus
}
#endif

#endif
