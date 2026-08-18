// TouchControls.mm - UIKit touch control helpers that still need UIKit.
//
// Contains the invisible keyboard field (for system-keyboard IME).
// The on-screen action button and D-pad live in GameControls.swift.
// The keyboard accessory bar lives in KeyboardAccessoryBar.swift.
//
// Engine communication goes through app_bridge.h functions.

#import "TouchControls.h"
#include "app_bridge.h"

// Minimum time a key stays down, in seconds. The engine samples key
// states once per frame, and heavy scenes run well below 40 fps. A
// shorter press can start and end between two samples, and the game
// never sees the key.
static const CGFloat kKeyMinHold = 0.1;

static void injectKey(int scancode, BOOL pressed) {
    mkxp_injectKeyEvent(scancode, pressed ? 1 : 0);
}

// TCKeyboardField (intercepts backspace)

@implementation TCKeyboardField

- (void)deleteBackward {
    injectKey(MKXP_SCANCODE_BACKSPACE, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKeyMinHold * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ injectKey(MKXP_SCANCODE_BACKSPACE, NO); });
}

- (CGRect)caretRectForPosition:(UITextPosition *)position {
    return CGRectZero;
}

// The field is an invisible scancode bridge, yet it is a real first
// responder at the center of the player view. Arrow keys move its
// text selection, and the system would draw the selection chrome
// mid-screen. Report no selection geometry, so nothing can draw.
- (NSArray<UITextSelectionRect *> *)selectionRectsForRange:(UITextRange *)range {
    return @[];
}

@end
