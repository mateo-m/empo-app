// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#import <UIKit/UIKit.h>

// A hidden text field. It gets the system keyboard input, also from
// an input method. KeyboardFieldRepresentable sends each key to the game.
@interface TCKeyboardField : UITextField
// UIKit inserts the text of a hardware key while its press is held.
// The text can come from another key: Q on AZERTY types "a".
@property (nonatomic, readonly) BOOL hardwareKeyTyping;
@property (nonatomic, copy, nullable) void (^onDeleteBackward)(void);
@end
