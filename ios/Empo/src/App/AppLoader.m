// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#import <UIKit/UIKit.h>
#import "AudioSession.h"

__attribute__((constructor)) static void appLoaderInit(void) {
    // Configure AVAudioSession synchronously at process startup,
    // BEFORE the engine's later `alcOpenDevice` runs. OpenAL-Soft
    // does not touch the session itself (Apple's deprecated
    // OpenAL framework used to do so implicitly). Without this
    // call audio would default to `SoloAmbient`: silenced on
    // device lock and on phone-mute. See AudioSession.m.
    EmpoConfigureAudioSession();
}
