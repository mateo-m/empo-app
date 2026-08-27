// EmpoAppDelegate.h
// The SDL app delegate, redeclared so Swift can subclass it.

#import <UIKit/UIKit.h>

/// SDL owns `main` and the app delegate. It picks the delegate class
/// by name, through `+getAppDelegateClassName`, and Empo overrides
/// that in a category. See `EmpoAppDelegateName.m`.
///
/// SDL keeps `SDL_uikitappdelegate.h` in its own sources and installs
/// no copy in `include/SDL2`, so the interface is here. The linker
/// takes the class itself from `-lSDL2`. Only the members Empo calls
/// are here.
@interface SDLUIKitDelegate : NSObject <UIApplicationDelegate>

+ (id)sharedAppDelegate;
+ (NSString *)getAppDelegateClassName;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions;

@end
