// TouchControls.mm - UIKit touch control helpers that still need UIKit.
//
// Contains the invisible keyboard field (for system-keyboard IME) and
// the keyboard accessory bar. The on-screen action button and D-pad
// used to live here as UIKit views; they have been replaced by the
// SwiftUI + Liquid Glass implementation in GameControls.swift.
//
// Engine communication goes through app_bridge.h functions.

#import "TouchControls.h"
#include "app_bridge.h"

static const CGFloat kAccessoryBarHeight = 80.0;
static const CGFloat kAccessoryFontSize  = 13.0;
static const CGFloat kKeyTapDuration     = 0.05; // seconds

static void injectKey(int scancode, BOOL pressed) {
    mkxp_injectKeyEvent(scancode, pressed ? 1 : 0);
}

NSString *const TCKeyEventNotification = @"TCKeyEvent";

static void keyEventBridgeCallback(int scancode, int pressed, void * /*userdata*/) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TCKeyEventNotification
                          object:nil
                        userInfo:@{
                            @"scancode": @(scancode),
                            @"pressed":  @(pressed),
                        }];
    });
}

static BOOL g_keyWatcherInstalled = NO;
void TCInstallKeyEventWatcher(void) {
    if (!g_keyWatcherInstalled) {
        mkxp_setKeyEventCallback(keyEventBridgeCallback, NULL);
        g_keyWatcherInstalled = YES;
    }
}

NSString *const TCTextInputModeNotification = @"TCTextInputMode";

// Engine fires this from EventThread (main thread) when
// SDL_StartTextInput / SDL_StopTextInput is dispatched. We bounce
// onto the main queue (no-op if already there) so SwiftUI can
// safely react via NotificationCenter.publisher.
static void textInputModeBridgeCallback(int active, void * /*userdata*/) {
    BOOL on = active ? YES : NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TCTextInputModeNotification
                          object:nil
                        userInfo:@{ @"active": @(on) }];
    });
}

static BOOL g_textInputWatcherInstalled = NO;
void TCInstallTextInputModeWatcher(void) {
    if (!g_textInputWatcherInstalled) {
        mkxp_setTextInputModeCallback(textInputModeBridgeCallback, NULL);
        g_textInputWatcherInstalled = YES;
    }
}

// Character-to-scancode mapping (for system keyboard)

static int scancodeForCharacter(unichar c) {
    if (c >= 'a' && c <= 'z') return (MKXP_SCANCODE_A + (c - 'a'));
    if (c >= 'A' && c <= 'Z') return (MKXP_SCANCODE_A + (c - 'A'));
    if (c >= '1' && c <= '9') return (MKXP_SCANCODE_1 + (c - '1'));
    if (c == '0') return MKXP_SCANCODE_0;
    switch (c) {
        case ' ':  return MKXP_SCANCODE_SPACE;
        case '\n': return MKXP_SCANCODE_RETURN;
        case '\t': return MKXP_SCANCODE_TAB;
        case '-':  return MKXP_SCANCODE_MINUS;
        case '=':  return MKXP_SCANCODE_EQUALS;
        case '[':  return MKXP_SCANCODE_LEFTBRACKET;
        case ']':  return MKXP_SCANCODE_RIGHTBRACKET;
        case '\\': return MKXP_SCANCODE_BACKSLASH;
        case ';':  return MKXP_SCANCODE_SEMICOLON;
        case '\'': return MKXP_SCANCODE_APOSTROPHE;
        case ',':  return MKXP_SCANCODE_COMMA;
        case '.':  return MKXP_SCANCODE_PERIOD;
        case '/':  return MKXP_SCANCODE_SLASH;
        case '`':  return MKXP_SCANCODE_GRAVE;
        default:   return MKXP_SCANCODE_UNKNOWN;
    }
}

// TCKeyboardField (intercepts backspace)

@implementation TCKeyboardField

- (void)deleteBackward {
    injectKey(MKXP_SCANCODE_BACKSPACE, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKeyTapDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        injectKey(MKXP_SCANCODE_BACKSPACE, NO);
    });
}

- (CGRect)caretRectForPosition:(UITextPosition *)position {
    return CGRectZero;
}

@end

// Keyboard accessory bar

@interface UIView (TCAccKeyActions)
- (void)accKeyTap:(UIButton *)sender;
- (void)accKeyDown:(UIButton *)sender;
- (void)accKeyUp:(UIButton *)sender;
@end

@implementation TCAccessoryBar
// TODO: Handle safe area insets for standalone accessory bar (no native keyboard).
// UIKit controls the input accessory view frame and ignores dynamic resizing.
// Needs a different approach — possibly recreating with correct height or
// not using inputAccessoryView at all.
@end

UIView *TCCreateKeyboardAccessoryView(void) {
    CGFloat barH = kAccessoryBarHeight;
    TCAccessoryBar *bar = [[TCAccessoryBar alloc] initWithFrame:CGRectMake(0, 0, 0, barH)];
    bar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // Row 1: F1-F12
    UIScrollView *fScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 2, 0, 36)];
    fScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    fScroll.showsHorizontalScrollIndicator = NO;
    [bar addSubview:fScroll];

    struct { const char *label; int sc; } fKeys[] = {
        {"F1",MKXP_SCANCODE_F1},{"F2",MKXP_SCANCODE_F2},{"F3",MKXP_SCANCODE_F3},
        {"F4",MKXP_SCANCODE_F4},{"F5",MKXP_SCANCODE_F5},{"F6",MKXP_SCANCODE_F6},
        {"F7",MKXP_SCANCODE_F7},{"F8",MKXP_SCANCODE_F8},{"F9",MKXP_SCANCODE_F9},
        {"F10",MKXP_SCANCODE_F10},{"F11",MKXP_SCANCODE_F11},{"F12",MKXP_SCANCODE_F12},
    };
    CGFloat fX = 6;
    for (int i = 0; i < 12; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *title = [NSString stringWithUTF8String:fKeys[i].label];
        [btn setTitle:title forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:kAccessoryFontSize weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
        btn.layer.cornerRadius = 5;
        CGFloat w = (i >= 9) ? 40 : 34;
        btn.frame = CGRectMake(fX, 2, w, 32);
        btn.tag = fKeys[i].sc;
        [btn addTarget:bar action:@selector(accKeyTap:) forControlEvents:UIControlEventTouchUpInside];
        [fScroll addSubview:btn];
        fX += w + 4;
    }
    fScroll.contentSize = CGSizeMake(fX, 36);

    // Row 2: modifiers + arrows
    UIScrollView *rScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 40, 0, 38)];
    rScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    rScroll.showsHorizontalScrollIndicator = NO;
    [bar addSubview:rScroll];

    struct { const char *label; int sc; BOOL holdable; } row2[] = {
        {"Esc",  MKXP_SCANCODE_ESCAPE, NO},
        {"Tab",  MKXP_SCANCODE_TAB,    NO},
        {"Ctrl", MKXP_SCANCODE_LCTRL,  YES},
        {"Shift",MKXP_SCANCODE_LSHIFT, YES},
        {"Alt",  MKXP_SCANCODE_LALT,   YES},
        {"\u2190",MKXP_SCANCODE_LEFT,  YES},
        {"\u2191",MKXP_SCANCODE_UP,    YES},
        {"\u2193",MKXP_SCANCODE_DOWN,  YES},
        {"\u2192",MKXP_SCANCODE_RIGHT, YES},
        {"Enter",MKXP_SCANCODE_RETURN, NO},
        {"Bksp", MKXP_SCANCODE_BACKSPACE, NO},
    };
    CGFloat rX = 6;
    int row2Count = sizeof(row2) / sizeof(row2[0]);
    for (int i = 0; i < row2Count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *title = [NSString stringWithUTF8String:row2[i].label];
        [btn setTitle:title forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:kAccessoryFontSize weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
        btn.layer.cornerRadius = 5;
        CGFloat w = 44;
        if (strlen(row2[i].label) <= 3 && row2[i].label[0] != '\\') w = 36;
        btn.frame = CGRectMake(rX, 2, w, 34);
        btn.tag = row2[i].sc;

        if (row2[i].holdable) {
            [btn addTarget:bar action:@selector(accKeyDown:) forControlEvents:UIControlEventTouchDown];
            [btn addTarget:bar action:@selector(accKeyUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        } else {
            [btn addTarget:bar action:@selector(accKeyTap:) forControlEvents:UIControlEventTouchUpInside];
        }
        [rScroll addSubview:btn];
        rX += w + 4;
    }
    rScroll.contentSize = CGSizeMake(rX, 38);

    return bar;
}

@implementation UIView (TCAccKeyActions)
- (void)accKeyTap:(UIButton *)sender {
    int sc = (int)sender.tag;
    injectKey(sc, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKeyTapDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        injectKey(sc, NO);
    });
}
- (void)accKeyDown:(UIButton *)sender {
    injectKey((int)sender.tag, YES);
}
- (void)accKeyUp:(UIButton *)sender {
    injectKey((int)sender.tag, NO);
}
@end
