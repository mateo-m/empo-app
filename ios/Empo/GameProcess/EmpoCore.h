// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

// Opens one game core for the whole process. The game process, Empo
// Player and the mkxp test host use it. GameCoreForwarders.c implements
// it, with a gamecore_* forwarder for each function of GameCore.h.

#ifndef EMPO_CORE_H
#define EMPO_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Opens the core at binaryPath, which is the Mach-O file inside the
// framework bundle, not the bundle, and finds each function of
// GameCore.h in it. Returns NULL on success, or the reason it failed.
// Call it once, before the first gamecore_* call.
const char *EmpoCoreOpen(const char *binaryPath);

#ifdef __cplusplus
}
#endif

#endif
