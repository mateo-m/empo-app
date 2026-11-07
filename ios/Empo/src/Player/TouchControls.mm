// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

// TouchControls.mm - UIKit touch control helpers that still need UIKit.
//
// Contains the invisible keyboard field (for system-keyboard IME).
// The on-screen action button and D-pad live in GameControls.swift.
// The keyboard accessory bar lives in KeyboardAccessoryBar.swift.

#import "TouchControls.h"

// TCKeyboardField (intercepts backspace)

@implementation TCKeyboardField {
    NSMutableSet<UIPress *> *_hardwarePresses;
}

- (BOOL)hardwareKeyTyping {
    for (UIPress *press in _hardwarePresses) {
        UIKeyboardHIDUsage code = press.key.keyCode;
        if (code < UIKeyboardHIDUsageKeyboardLeftControl || code > UIKeyboardHIDUsageKeyboardRightGUI)
            return YES;
    }
    return NO;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (!_hardwarePresses)
        _hardwarePresses = [NSMutableSet set];
    for (UIPress *press in presses) {
        if (press.key)
            [_hardwarePresses addObject:press];
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [super pressesEnded:presses withEvent:event];
    [_hardwarePresses minusSet:presses];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [super pressesCancelled:presses withEvent:event];
    [_hardwarePresses minusSet:presses];
}

// UIKit can stop sending press ends after the field resigns. A press
// left in the set would hide every later on-screen key.
- (BOOL)resignFirstResponder {
    BOOL resigned = [super resignFirstResponder];
    if (resigned)
        [_hardwarePresses removeAllObjects];
    return resigned;
}

- (void)deleteBackward {
    if (self.onDeleteBackward)
        self.onDeleteBackward();
}

// On iPadOS, Tab moves keyboard focus to any text field, and the field
// then takes the keys from a game in its own process.
- (BOOL)canBecomeFocused {
    return self.isFirstResponder;
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
