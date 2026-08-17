// TouchControls.h - UIKit touch control helpers that still need UIKit.
//
// This header used to include TCButton (on-screen action button),
// TCDPadView (on-screen directional pad), and TCAccessoryBar (the
// keyboard accessory). All three have been replaced by SwiftUI +
// Liquid Glass equivalents: the controls live in GameControls.swift
// and the accessory bar in KeyboardAccessoryBar.swift. What's left
// here is the invisible keyboard field that UIKit has to own (for
// system-keyboard IME and scancode injection on key events).

#import <UIKit/UIKit.h>

// TCKeyboardField - hidden text field for system keyboard input
@interface TCKeyboardField : UITextField
@end
