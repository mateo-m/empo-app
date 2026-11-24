// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "ScreenRate.h"

@interface EmpoScreenRate : NSObject
@end

@implementation EmpoScreenRate

+ (void)refresh:(CADisplayLink *)link {
}

@end

bool EmpoGameNeeds120Hz(int gameRate) {
    return gameRate > 0 && 60 % gameRate != 0;
}

void EmpoSetGameRate(int gameRate) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static CADisplayLink *link;
        if (!EmpoGameNeeds120Hz(gameRate) || UIScreen.mainScreen.maximumFramesPerSecond <= 60) {
            [link invalidate];
            link = nil;
            return;
        }
        if (link != nil) {
            return;
        }
        // A 120 Hz iPhone refreshes at 60 Hz for a Metal layer, so a game
        // at 40 frames per second shows its frames for 16.7 ms and 33.3 ms
        // in turn. The screen goes to 120 Hz only while a display link of
        // the process that draws asks for 120, and only with
        // CADisableMinimumFrameDurationOnPhone in the Info.plist of that
        // process.
        link = [CADisplayLink displayLinkWithTarget:EmpoScreenRate.class selector:@selector(refresh:)];
        link.preferredFrameRateRange = CAFrameRateRangeMake(120, 120, 120);
        [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    });
}
