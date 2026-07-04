// TouchControls.h - UIKit touch control helpers that still need UIKit.
//
// This header used to include TCButton (on-screen action button) and
// TCDPadView (on-screen directional pad). Both have been replaced by
// SwiftUI + Liquid Glass equivalents in GameControls.swift; what's
// left here is the invisible keyboard field that UIKit has to own
// (for system-keyboard IME and scancode injection on key events).

#import <UIKit/UIKit.h>

// TCAccessoryBar - keyboard accessory that respects safe area insets
@interface TCAccessoryBar : UIView
@end

// TCKeyboardField - hidden text field for system keyboard input
@interface TCKeyboardField : UITextField
@end

#ifdef __cplusplus
extern "C" {
#endif

UIView *TCCreateKeyboardAccessoryView(void);

#ifdef __cplusplus
}
#endif
