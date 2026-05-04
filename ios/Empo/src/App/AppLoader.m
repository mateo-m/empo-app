#import <UIKit/UIKit.h>
#import "Empo-Swift.h"
#import "AudioSession.h"

__attribute__((constructor)) static void appLoaderInit(void) {
    // Configure AVAudioSession synchronously at process startup,
    // BEFORE the engine's later `alcOpenDevice` runs. OpenAL-Soft
    // does not touch the session itself (Apple's deprecated
    // OpenAL framework used to do so implicitly). Without this
    // call audio would default to `SoloAmbient`: silenced on
    // device lock and on phone-mute. See AudioSession.m.
    mkxp_configureAudioSession();

    dispatch_async(dispatch_get_main_queue(), ^{ [AppWindow install]; });
}
