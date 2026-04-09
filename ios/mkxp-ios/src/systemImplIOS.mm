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
