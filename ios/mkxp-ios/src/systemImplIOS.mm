#import <UIKit/UIKit.h>
#import "system.h"
#import "ios_bridge.h"

std::string systemImpl::getSystemLanguage() {
    @autoreleasepool {
        return std::string(NSLocale.currentLocale.localeIdentifier.UTF8String);
    }
}

std::string systemImpl::getUserName() {
    @autoreleasepool {
        return std::string("Player");
    }
}

int systemImpl::getScalingFactor() {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            return (int)ws.traitCollection.displayScale;
        }
    }
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
    return true;
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


float mkxp_getScreenScale(void) {
    // Screen scale is a device constant (e.g. 3.0 on iPhone Pro) that
    // never changes at runtime.  Cache it to avoid dispatch_sync to the
    // main queue on every resize — that call can stall the RGSS thread
    // during rapid rotation while UIKit is processing layout animations.
    static float cachedScale = 0.0f;
    if (cachedScale > 0.0f)
        return cachedScale;

    __block float scale = 2.0f;

    void (^queryBlock)(void) = ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                scale = ws.traitCollection.displayScale;
                break;
            }
        }
    };

    if ([NSThread isMainThread]) {
        queryBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), queryBlock);
    }

    cachedScale = scale;
    return scale;
}
