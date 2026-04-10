// TouchControls.h — UIKit touch control classes for UIViewRepresentable wrapping.
//
// Contains: TCButton, TCDPadView, TCKeyboardField, keyboard accessory creation.
// These are the UIKit views that need precise touch handling (raw touches,
// continuous directional tracking, etc.) and are wrapped as UIViewRepresentable
// in Swift for use in the SwiftUI player view.

#import <UIKit/UIKit.h>

// ============================================================================
// TCButton — individual circular action button
// ============================================================================

@interface TCButton : UIView
@property (nonatomic) int scancode;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) BOOL editing;
@property (nonatomic) BOOL active;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIView *deleteBadge;
/// Position stored as fraction of superview size (for persistence / rotation)
@property (nonatomic) CGPoint relativeCenter;

- (instancetype)initWithLabel:(NSString *)label scancode:(int)sc size:(CGFloat)size;
- (void)resizeToSize:(CGFloat)newSize animated:(BOOL)animated;
- (void)updateLabel:(NSString *)newLabel;
- (NSDictionary *)toDict;
+ (TCButton *)fromDict:(NSDictionary *)d;
@end

// ============================================================================
// TCDPadView — directional pad with 8-way input
// ============================================================================

typedef NS_OPTIONS(NSUInteger, DPadDirection) {
    DPadNone  = 0,
    DPadUp    = 1 << 0,
    DPadDown  = 1 << 1,
    DPadLeft  = 1 << 2,
    DPadRight = 1 << 3,
};

@interface TCDPadView : UIView
@property (nonatomic) DPadDirection activeDirections;
@property (nonatomic) BOOL editing;
@property (nonatomic) CGPoint relativeCenter;

- (instancetype)initWithSize:(CGFloat)size;
- (NSDictionary *)toDict;
@end

// ============================================================================
// TCAccessoryBar — keyboard accessory that respects safe area insets
@interface TCAccessoryBar : UIView
@end

// TCKeyboardField — hidden text field for system keyboard input
// ============================================================================

@interface TCKeyboardField : UITextField
@end

// ============================================================================
// Keyboard accessory bar creation
// ============================================================================

#ifdef __cplusplus
extern "C" {
#endif

UIView *TCCreateKeyboardAccessoryView(void);

// ============================================================================
// Key event watcher (installs once, dispatches via NotificationCenter)
// ============================================================================

extern NSString *const TCKeyEventNotification;

void TCInstallKeyEventWatcher(void);

#ifdef __cplusplus
}
#endif
