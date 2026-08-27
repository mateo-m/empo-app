#import "EmpoAppDelegate.h"

/// Points SDL at Empo's own delegate.
///
/// SDL calls `NSClassFromString([[self class] getAppDelegateClassName])`
/// from its `main`, and its own header tells a subclass to override
/// the method in a category. `EmpoAppDelegate` is the Swift class of
/// the same name, which carries `@objc(EmpoAppDelegate)`.
// The category replaces a method the class already has. That is
// what SDL asks a subclass to do, so the warning is the plan.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation SDLUIKitDelegate (Empo)

+ (NSString *)getAppDelegateClassName {
    return @"EmpoAppDelegate";
}

@end

#pragma clang diagnostic pop
