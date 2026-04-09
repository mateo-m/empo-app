//
//  systemImplIOS.mm
//  mkxp-ios
//
//  iOS implementation of system functions
//

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <sys/sysctl.h>
#import "system.h"
#import "ios_bridge.h"

std::string systemImpl::getSystemLanguage() {
    @autoreleasepool {
        NSString *languageCode = NSLocale.currentLocale.languageCode;
        NSString *countryCode = NSLocale.currentLocale.countryCode;
        return std::string([NSString stringWithFormat:@"%@_%@", languageCode, countryCode].UTF8String);
    }
}

std::string systemImpl::getUserName() {
    @autoreleasepool {
        return std::string("Player");
    }
}

int systemImpl::getScalingFactor() {
    // UIScreen.mainScreen is deprecated in iOS 26.
    // Walk the connected scenes to find a UIWindowScene and its screen.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            return (int)ws.screen.scale;
        }
    }
    // Fallback – should not happen in practice.
    return 2;
}

bool systemImpl::isWine() {
    return false;
}

bool systemImpl::isRosetta() {
    return false;
}

systemImpl::WineHostType systemImpl::getRealHostType() {
    return WineHostType::Mac;
}

void openSettingsWindow() {
    // No settings window on iOS
}

bool isMetalSupported() {
    return MTLCreateSystemDefaultDevice() != nil;
}

std::string getPlistValue(const char *key) {
    @autoreleasepool {
        NSString *hash = [[NSBundle mainBundle] objectForInfoDictionaryKey:@(key)];
        if (hash != nil) {
            return std::string(hash.UTF8String);
        }
        return "";
    }
}

void mkxp_getSafeAreaInsets(float *top, float *bottom, float *left, float *right) {
    __block UIEdgeInsets insets = UIEdgeInsetsZero;

    void (^queryBlock)(void) = ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;

            // Prefer a window with nonzero safe area insets (the touch overlay
            // or any UIKit window). SDL's CAEAGLLayer window may report zero
            // insets, so avoid selecting it as "best" when better options exist.
            UIWindow *best = nil;
            UIWindow *keyWin = nil;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) keyWin = w;
                if (!UIEdgeInsetsEqualToEdgeInsets(w.safeAreaInsets, UIEdgeInsetsZero)) {
                    best = w;
                    break;  // first window with real insets wins
                }
            }
            if (!best) best = keyWin;
            if (!best && ws.windows.count > 0)
                best = ws.windows.firstObject;
            if (best) {
                insets = best.safeAreaInsets;
                break;
            }
        }
    };

    if ([NSThread isMainThread]) {
        queryBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), queryBlock);
    }

    if (top)    *top    = insets.top;
    if (bottom) *bottom = insets.bottom;
    if (left)   *left   = insets.left;
    if (right)  *right  = insets.right;
}

float mkxp_getScreenScale(void) {
    __block float scale = 2.0f;

    void (^queryBlock)(void) = ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                scale = ws.screen.scale;
                break;
            }
        }
    };

    if ([NSThread isMainThread]) {
        queryBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), queryBlock);
    }

    return scale;
}
