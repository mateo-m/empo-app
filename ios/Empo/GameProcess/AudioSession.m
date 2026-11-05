// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#import <AVFoundation/AVFoundation.h>
#import "AudioSession.h"

// OpenAL-Soft talks straight to AudioUnit and never sets a category.
// Without one, the process gets SoloAmbient, which stops the user's
// music when a game starts.
void EmpoConfigureAudioSession(bool respectsSilentMode) {
    AVAudioSession *session = [AVAudioSession sharedInstance];

    // The Ring/Silent switch mutes Ambient and does not mute Playback.
    NSError *categoryError = nil;
    [session setCategory:respectsSilentMode ? AVAudioSessionCategoryAmbient : AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&categoryError];
    if (categoryError) {
        NSLog(@"[AudioSession] setCategory failed: %@", categoryError);
    }

    NSError *activateError = nil;
    [session setActive:YES error:&activateError];
    if (activateError) {
        NSLog(@"[AudioSession] setActive failed: %@", activateError);
    }
}
