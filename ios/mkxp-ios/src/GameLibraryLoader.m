#import <UIKit/UIKit.h>
#import "mkxp_z-Swift.h"

// +load is called before main(), which is perfect for scheduling
// the library install. We dispatch to main queue because we need
// UIApplication to be set up before creating windows.
@interface _GameLibraryLoader : NSObject
@end

@implementation _GameLibraryLoader
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        [GameLibraryWindow install];
    });
}
@end
