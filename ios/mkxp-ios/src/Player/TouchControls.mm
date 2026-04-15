// TouchControls.mm — UIKit touch control classes.
//
// Contains only the UIKit views that require raw touch handling:
// TCButton, TCDPadView, TCKeyboardField, keyboard accessory bar.
// These are wrapped as UIViewRepresentable in Swift for use in PlayerView.
//
// All engine communication goes through ios_bridge.h functions.

#import "TouchControls.h"
#include "ios_bridge.h"

// ============================================================================
// MARK: - Constants
// ============================================================================

static const CGFloat kButtonSize         = 56.0;
static const CGFloat kDPadDeadZone       = 0.20; // fraction of radius
static const CGFloat kButtonHitSlop      = 10.0; // extra radius for pointInside
static const CGFloat kDPadHitSlop        = 15.0; // extra radius for pointInside
static const CGFloat kDPadCancelRadius   = 30.0; // extra radius before cancel on move
static const CGFloat kBorderWidth        = 1.5;
static const CGFloat kDeleteBadgeSize    = 22.0;
static const CGFloat kSmallFontThreshold = 50.0; // below this size, use small font
static const CGFloat kSmallFontSize      = 12.0;
static const CGFloat kLargeFontSize      = 16.0;
static const CGFloat kArrowFontSize      = 16.0;
static const CGFloat kAccessoryBarHeight = 80.0;
static const CGFloat kAccessoryFontSize  = 13.0;
static const CGFloat kKeyTapDuration     = 0.05; // seconds
static const CGFloat kPressScale         = 0.90;

// ============================================================================
// MARK: - Key event injection (via bridge)
// ============================================================================

static void injectKey(int scancode, BOOL pressed) {
    mkxp_injectKeyEvent(scancode, pressed ? 1 : 0);
}

// ============================================================================
// MARK: - Controller haptics
// ============================================================================

static BOOL controllerHapticsEnabled(void) {
    // Defaults to YES when the key hasn't been set yet
    NSObject *val = [[NSUserDefaults standardUserDefaults] objectForKey:@"controllerHaptics"];
    return val ? [[NSUserDefaults standardUserDefaults] boolForKey:@"controllerHaptics"] : YES;
}

// ============================================================================
// MARK: - Key event watcher (highlights buttons on hardware key events)
// ============================================================================

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

// ============================================================================
// MARK: - Character-to-scancode mapping (for system keyboard)
// ============================================================================

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

// ============================================================================
// MARK: - TCButton (individual action button)
// ============================================================================

@interface TCButton ()
@property (nonatomic, weak) UITouch *trackedTouch;
@property (nonatomic, strong) UIImpactFeedbackGenerator *haptic;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@end

@implementation TCButton

- (instancetype)initWithLabel:(NSString *)label scancode:(int)sc size:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0, 0, size, size)];
    if (self) {
        _scancode = sc;
        _label = [label copy];
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        self.multipleTouchEnabled = NO;
        self.exclusiveTouch = NO;
        self.backgroundColor = UIColor.clearColor;
        self.layer.cornerRadius = size / 2.0;

        // Glass-like blur background
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        _blurView.layer.cornerRadius = size / 2.0;
        _blurView.clipsToBounds = YES;
        [self addSubview:_blurView];

        // Subtle border
        self.layer.borderWidth = kBorderWidth;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;

        _textLabel = [[UILabel alloc] initWithFrame:self.bounds];
        _textLabel.text = label;
        _textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        _textLabel.font = [UIFont systemFontOfSize:(size < kSmallFontThreshold ? kSmallFontSize : kLargeFontSize) weight:UIFontWeightSemibold];
        _textLabel.textAlignment = NSTextAlignmentCenter;
        _textLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_textLabel];
    }
    return self;
}

- (void)setActive:(BOOL)active {
    _active = active;
    [UIView animateWithDuration:0.15
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = active ? CGAffineTransformMakeScale(kPressScale, kPressScale) : CGAffineTransformIdentity;
        self.layer.borderColor = active
            ? [UIColor colorWithWhite:1.0 alpha:0.6].CGColor
            : [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    } completion:nil];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
}

- (void)setDragging:(BOOL)dragging {
    _dragging = dragging;
    [UIView animateWithDuration:0.15
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.layer.borderColor = dragging
            ? [UIColor colorWithWhite:1.0 alpha:0.6].CGColor
            : [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    } completion:nil];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat cx = self.bounds.size.width * 0.5;
    CGFloat cy = self.bounds.size.height * 0.5;
    CGFloat r = cx + kButtonHitSlop;
    CGFloat dx = point.x - cx, dy = point.y - cy;
    return (dx * dx + dy * dy) <= (r * r);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) return;
    UITouch *t = touches.anyObject;
    _trackedTouch = t;
    self.active = YES;
    injectKey(_scancode, YES);
    if (controllerHapticsEnabled()) [_haptic impactOccurred];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) return;
    if ([touches containsObject:_trackedTouch] || _trackedTouch == nil) {
        self.active = NO;
        injectKey(_scancode, NO);
        _trackedTouch = nil;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

- (void)resizeToSize:(CGFloat)newSize animated:(BOOL)animated {
    (void)animated;
    [self _applySize:newSize];
}

- (void)_applySize:(CGFloat)newSize {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGPoint c = self.center;
    self.bounds = CGRectMake(0, 0, newSize, newSize);
    self.center = c;
    self.layer.cornerRadius = newSize / 2.0;
    _blurView.frame = self.bounds;
    _blurView.layer.cornerRadius = newSize / 2.0;
    _textLabel.frame = self.bounds;
    _textLabel.font = [UIFont systemFontOfSize:(newSize < kSmallFontThreshold ? kSmallFontSize : kLargeFontSize) weight:UIFontWeightSemibold];
    [CATransaction commit];
}

- (void)updateLabel:(NSString *)newLabel {
    _label = [newLabel copy];
    _textLabel.text = newLabel;
}

- (NSDictionary *)toDict {
    return @{
        @"label":    _label ?: @"",
        @"scancode": @((int)_scancode),
        @"rx":       @(_relativeCenter.x),
        @"ry":       @(_relativeCenter.y),
        @"size":     @(self.bounds.size.width),
    };
}

+ (TCButton *)fromDict:(NSDictionary *)d {
    CGFloat size = [d[@"size"] floatValue] ?: kButtonSize;
    TCButton *b = [[TCButton alloc] initWithLabel:d[@"label"]
                                         scancode:(int)[d[@"scancode"] intValue]
                                             size:size];
    b.relativeCenter = CGPointMake([d[@"rx"] floatValue], [d[@"ry"] floatValue]);
    return b;
}

@end

// ============================================================================
// TCDPadOverlayView — transparent overlay that draws cross arms and arrows
// on top of the blur view (drawRect on the parent would render behind it).
// ============================================================================

@interface TCDPadOverlayView : UIView
@property (nonatomic, assign) DPadDirection activeDirections;
@end

@implementation TCDPadOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat s = rect.size.width;
    CGFloat armW = s * 0.34;
    CGFloat off = (s - armW) / 2.0;
    CGFloat inset = 6;

    UIBezierPath *cross = [UIBezierPath bezierPath];
    [cross appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(off, inset, armW, s - inset * 2)
                                                 cornerRadius:armW * 0.25]];
    [cross appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(inset, off, s - inset * 2, armW)
                                                 cornerRadius:armW * 0.25]];

    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.08].CGColor);
    [cross fill];

    CGFloat qS = armW * 0.65;
    CGFloat cx = s / 2, cy = s / 2;
    struct { DPadDirection d; CGFloat x, y; const char *arrow; } dirs[] = {
        {DPadUp,    cx, cy - s * 0.27, "\u25B2"},
        {DPadDown,  cx, cy + s * 0.27, "\u25BC"},
        {DPadLeft,  cx - s * 0.27, cy, "\u25C0"},
        {DPadRight, cx + s * 0.27, cy, "\u25B6"},
    };
    for (int i = 0; i < 4; i++) {
        BOOL active = (_activeDirections & dirs[i].d) != 0;
        if (active) {
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.25].CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(dirs[i].x - qS/2, dirs[i].y - qS/2, qS, qS));
        }
        NSString *arrow = [NSString stringWithUTF8String:dirs[i].arrow];
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = NSTextAlignmentCenter;
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:kArrowFontSize weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:(active ? 1.0 : 0.5)],
            NSParagraphStyleAttributeName: ps,
        };
        CGSize ts = [arrow sizeWithAttributes:attrs];
        [arrow drawInRect:CGRectMake(dirs[i].x - ts.width/2, dirs[i].y - ts.height/2, ts.width, ts.height)
           withAttributes:attrs];
    }
}

@end

// ============================================================================
// TCDPadView (directional pad)
// ============================================================================

@interface TCDPadView ()
@property (nonatomic, weak) UITouch *trackedTouch;
@property (nonatomic, strong) UISelectionFeedbackGenerator *haptic;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) TCDPadOverlayView *overlayView;
@end

@implementation TCDPadView

- (instancetype)initWithSize:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0, 0, size, size)];
    if (self) {
        _haptic = [[UISelectionFeedbackGenerator alloc] init];
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = NO;
        self.exclusiveTouch = NO;
        self.clipsToBounds = YES;
        self.layer.cornerRadius = size / 2.0;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        _blurView.layer.cornerRadius = size / 2.0;
        _blurView.clipsToBounds = YES;
        [self addSubview:_blurView];

        _overlayView = [[TCDPadOverlayView alloc] initWithFrame:self.bounds];
        _overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_overlayView];

        self.layer.borderWidth = kBorderWidth;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    }
    return self;
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
}

- (void)setDragging:(BOOL)dragging {
    _dragging = dragging;
    [UIView animateWithDuration:0.15
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.layer.borderColor = dragging
            ? [UIColor colorWithWhite:1.0 alpha:0.6].CGColor
            : [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    } completion:nil];
}

- (DPadDirection)directionForTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    CGFloat cx = self.bounds.size.width / 2;
    CGFloat cy = self.bounds.size.height / 2;
    CGFloat dx = p.x - cx;
    CGFloat dy = p.y - cy;
    CGFloat radius = self.bounds.size.width / 2;
    CGFloat dist = sqrtf(dx * dx + dy * dy);

    if (dist < radius * kDPadDeadZone) return DPadNone;

    CGFloat angle = atan2f(-dy, dx);
    DPadDirection dir = DPadNone;

    if (angle > -M_PI/8 && angle <= M_PI/8)         dir = DPadRight;
    else if (angle > M_PI/8 && angle <= 3*M_PI/8)   dir = DPadRight | DPadUp;
    else if (angle > 3*M_PI/8 && angle <= 5*M_PI/8) dir = DPadUp;
    else if (angle > 5*M_PI/8 && angle <= 7*M_PI/8) dir = DPadLeft | DPadUp;
    else if (angle > 7*M_PI/8 || angle <= -7*M_PI/8) dir = DPadLeft;
    else if (angle > -7*M_PI/8 && angle <= -5*M_PI/8) dir = DPadLeft | DPadDown;
    else if (angle > -5*M_PI/8 && angle <= -3*M_PI/8) dir = DPadDown;
    else if (angle > -3*M_PI/8 && angle <= -M_PI/8)  dir = DPadRight | DPadDown;

    return dir;
}

- (void)updateDirections:(DPadDirection)newDir {
    DPadDirection old = _activeDirections;
    if (old == newDir) return;

    if ((old & DPadUp)    && !(newDir & DPadUp))    injectKey(MKXP_SCANCODE_UP, NO);
    if ((old & DPadDown)  && !(newDir & DPadDown))  injectKey(MKXP_SCANCODE_DOWN, NO);
    if ((old & DPadLeft)  && !(newDir & DPadLeft))  injectKey(MKXP_SCANCODE_LEFT, NO);
    if ((old & DPadRight) && !(newDir & DPadRight)) injectKey(MKXP_SCANCODE_RIGHT, NO);

    if (!(old & DPadUp)    && (newDir & DPadUp))    injectKey(MKXP_SCANCODE_UP, YES);
    if (!(old & DPadDown)  && (newDir & DPadDown))  injectKey(MKXP_SCANCODE_DOWN, YES);
    if (!(old & DPadLeft)  && (newDir & DPadLeft))  injectKey(MKXP_SCANCODE_LEFT, YES);
    if (!(old & DPadRight) && (newDir & DPadRight)) injectKey(MKXP_SCANCODE_RIGHT, YES);

    _activeDirections = newDir;
    _overlayView.activeDirections = newDir;
    [_overlayView setNeedsDisplay];

    // Tick on direction change (not on release)
    if (newDir != DPadNone && controllerHapticsEnabled()) {
        [_haptic selectionChanged];
    }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat r = self.bounds.size.width / 2 + kDPadHitSlop;
    CGFloat cx = self.bounds.size.width / 2;
    CGFloat cy = self.bounds.size.height / 2;
    CGFloat dx = point.x - cx, dy = point.y - cy;
    return (dx*dx + dy*dy) <= r*r;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) return;
    UITouch *t = touches.anyObject;
    _trackedTouch = t;
    if (controllerHapticsEnabled()) [_haptic prepare];
    [self updateDirections:[self directionForTouch:t]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) return;
    UITouch *t = _trackedTouch;
    if (t && [touches containsObject:t]) {
        CGPoint p = [t locationInView:self];
        CGFloat r = self.bounds.size.width / 2 + kDPadCancelRadius;
        CGFloat cx = self.bounds.size.width / 2;
        CGFloat cy = self.bounds.size.height / 2;
        CGFloat dx = p.x - cx, dy = p.y - cy;
        if ((dx*dx + dy*dy) > r*r) {
            [self updateDirections:DPadNone];
        } else {
            [self updateDirections:[self directionForTouch:t]];
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) return;
    if ([touches containsObject:_trackedTouch] || _trackedTouch == nil) {
        [self updateDirections:DPadNone];
        _trackedTouch = nil;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

- (NSDictionary *)toDict {
    return @{
        @"rx":   @(_relativeCenter.x),
        @"ry":   @(_relativeCenter.y),
        @"size": @(self.bounds.size.width),
    };
}

@end

// ============================================================================
// MARK: - TCKeyboardField (intercepts backspace)
// ============================================================================

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

// ============================================================================
// MARK: - Keyboard accessory bar
// ============================================================================

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
