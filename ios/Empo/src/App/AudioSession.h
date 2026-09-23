#ifndef EMPO_AUDIO_SESSION_H
#define EMPO_AUDIO_SESSION_H

#ifdef __cplusplus
extern "C" {
#endif

/// Configure `AVAudioSession` for game playback. Must run at
/// process startup, before any code calls `alcOpenDevice` (so
/// before `AppWindow.install` schedules the engine bootstrap).
/// See AudioSession.m for rationale.
void EmpoConfigureAudioSession(void);

#ifdef __cplusplus
}
#endif

#endif
