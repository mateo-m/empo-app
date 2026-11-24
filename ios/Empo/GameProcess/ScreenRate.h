// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#ifndef EMPO_SCREEN_RATE_H
#define EMPO_SCREEN_RATE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Call it in the process that draws the game, from any thread: with the
/// frames per second of the game when the game draws its first frame
/// after a start or a resume, and with 0 when the game pauses or ends.
/// Read the rate on the thread of the game. The core frees its data
/// before it reports its end, so a read from another thread can come
/// too late.
void EmpoSetGameRate(int gameRate);

bool EmpoGameNeeds120Hz(int gameRate);

#ifdef __cplusplus
}
#endif

#endif
