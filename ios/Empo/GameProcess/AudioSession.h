// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#ifndef EMPO_AUDIO_SESSION_H
#define EMPO_AUDIO_SESSION_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Sets the `AVAudioSession` of the process that plays the game. Call
/// it before the game opens its audio device, and again when the
/// setting changes.
void EmpoConfigureAudioSession(bool respectsSilentMode);

#ifdef __cplusplus
}
#endif

#endif
