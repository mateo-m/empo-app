#import <UIKit/UIKit.h>
#import "mkxp_z-Swift.h"

// +load is called before main(), which is perfect for scheduling
// the app window install. We dispatch to main queue because we need
// UIApplication to be set up before creating windows.
@interface _AppLoader : NSObject
@end

@implementation _AppLoader
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        [AppWindow install];
    });
}
@end
