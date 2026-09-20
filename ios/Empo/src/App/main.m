// Process entry.
//
// Empo owns UIApplicationMain. It used to come from libSDL2main, which
// ran SDLUIKitDelegate, which called the engine's SDL_main. The engine
// now sits in MkxpCore.framework, which Empo opens with dlopen when the
// user picks a game, so neither that main nor that delegate is
// reachable at launch.
//
// EmpoAppDelegate does nothing. UIKit needs an application delegate
// class, and EmpoSceneDelegate (named in Info.plist) builds the UI.
// SDL does not need one either: it watches the lifecycle through
// NSNotificationCenter observers that SDL_iPhoneSetEventPump installs
// (SDL_uikitevents.m:45-63).

#import <UIKit/UIKit.h>

#include "EmpoCore.h"
#include "GameCore.h"

@interface EmpoAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation EmpoAppDelegate
@end

static int gArgc;
static char **gArgv;

int EmpoCoreRunEngine(void) {
    return gamecore_run_app(gArgc, gArgv);
}

int main(int argc, char *argv[]) {
    gArgc = argc;
    gArgv = argv;
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(EmpoAppDelegate.class));
    }
}
