#import <UIKit/UIKit.h>
#import "mkxp_z-Swift.h"

__attribute__((constructor))
static void appLoaderInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [AppWindow install];
    });
}
