#import <AVFoundation/AVFoundation.h>
#import "AudioSession.h"

// Configure AVAudioSession at process startup, BEFORE the engine
// calls `alcOpenDevice`.
//
// Why this exists: under Apple's deprecated `-framework OpenAL`,
// the framework's iOS implementation hooked AVAudioSession on our
// behalf, picking a default category that worked for casual use.
// We've moved to OpenAL-Soft's CoreAudio backend, which talks
// straight to AudioUnit and never touches AVAudioSession. Without
// an explicit category set, the process inherits
// `AVAudioSessionCategorySoloAmbient`:
//   - audio is silenced when the device is locked,
//   - other audio (Music app, podcasts) is interrupted on launch,
//   - phone-mute switch silences playback.
//
// `AVAudioSessionCategoryPlayback` is the right category for a
// game: audio keeps playing through the lock screen and the
// silent switch (matches Music app / Podcasts / Spotify
// behavior). `MixWithOthers` lets the user keep their own music
// running on top of the game if they want; if a game ships its
// own BGM, this is a friendlier default than ducking everything
// else. Users who want exclusive audio can pause their music
// from Control Center.
//
// Idempotent: calling it again before the first audio session
// is activated is a no-op; calling after activation just updates
// the category. Safe to invoke multiple times.
void mkxp_configureAudioSession(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];

    NSError *categoryError = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
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
