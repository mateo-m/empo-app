// Process entry.
//
// Empo owns UIApplicationMain. No engine runs in this process: each game
// runs in its own game process (GameProcessHost.swift).
//
// EmpoAppDelegate does nothing. UIKit needs an application delegate
// class, and EmpoSceneDelegate (named in Info.plist) builds the UI.

#import <UIKit/UIKit.h>

@interface EmpoAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation EmpoAppDelegate
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(EmpoAppDelegate.class));
    }
}
