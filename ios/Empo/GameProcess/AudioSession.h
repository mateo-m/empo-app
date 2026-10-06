#ifndef EMPO_AUDIO_SESSION_H
#define EMPO_AUDIO_SESSION_H

#ifdef __cplusplus
extern "C" {
#endif

/// Configure `AVAudioSession` for game playback. Must run in the
/// process of the game before the core opens, so before any code
/// calls `alcOpenDevice`. See AudioSession.m for rationale.
void EmpoConfigureAudioSession(void);

#ifdef __cplusplus
}
#endif

#endif
