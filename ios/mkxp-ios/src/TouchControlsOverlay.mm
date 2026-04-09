#import "TouchControlsOverlay.h"
#import <SDL.h>
#include "ios_bridge.h"

// ============================================================================
// MARK: - Constants
// ============================================================================

static const CGFloat kDPadSize        = 140.0;
static const CGFloat kDPadDeadZone    = 0.20; // fraction of radius
static const CGFloat kButtonSize      = 56.0;
static const CGFloat kSmallButtonSize = 38.0;
static const CGFloat kEdgeInset       = 20.0;

static NSString *const kSavedLayoutKey = @"touchControlsLayout";

// ============================================================================
// MARK: - Key catalog for the "Add Button" picker
// ============================================================================

typedef struct {
    const char *label;
    SDL_Scancode scancode;
} KeyEntry;

static const KeyEntry kKeyCatalog[] = {
    // Common RPG Maker keys
    {"Z (Confirm)",  SDL_SCANCODE_Z},
    {"X (Cancel)",   SDL_SCANCODE_X},
    {"Shift (Dash)", SDL_SCANCODE_LSHIFT},
    {"Ctrl (Skip)",  SDL_SCANCODE_LCTRL},
    {"Space",        SDL_SCANCODE_SPACE},
    {"Enter",        SDL_SCANCODE_RETURN},
    {"Escape",       SDL_SCANCODE_ESCAPE},
    {"Tab",          SDL_SCANCODE_TAB},
    // Letters
    {"A", SDL_SCANCODE_A}, {"B", SDL_SCANCODE_B}, {"C", SDL_SCANCODE_C},
    {"D", SDL_SCANCODE_D}, {"E", SDL_SCANCODE_E}, {"F", SDL_SCANCODE_F},
    {"G", SDL_SCANCODE_G}, {"H", SDL_SCANCODE_H}, {"I", SDL_SCANCODE_I},
    {"J", SDL_SCANCODE_J}, {"K", SDL_SCANCODE_K}, {"L", SDL_SCANCODE_L},
    {"M", SDL_SCANCODE_M}, {"N", SDL_SCANCODE_N}, {"O", SDL_SCANCODE_O},
    {"P", SDL_SCANCODE_P}, {"Q", SDL_SCANCODE_Q}, {"R", SDL_SCANCODE_R},
    {"S", SDL_SCANCODE_S}, {"T", SDL_SCANCODE_T}, {"U", SDL_SCANCODE_U},
    {"V", SDL_SCANCODE_V}, {"W", SDL_SCANCODE_W}, {"Y", SDL_SCANCODE_Y},
    // Numbers
    {"0", SDL_SCANCODE_0}, {"1", SDL_SCANCODE_1}, {"2", SDL_SCANCODE_2},
    {"3", SDL_SCANCODE_3}, {"4", SDL_SCANCODE_4}, {"5", SDL_SCANCODE_5},
    {"6", SDL_SCANCODE_6}, {"7", SDL_SCANCODE_7}, {"8", SDL_SCANCODE_8},
    {"9", SDL_SCANCODE_9},
    // Function keys
    {"F1", SDL_SCANCODE_F1}, {"F2", SDL_SCANCODE_F2}, {"F3", SDL_SCANCODE_F3},
    {"F4", SDL_SCANCODE_F4}, {"F5", SDL_SCANCODE_F5}, {"F6", SDL_SCANCODE_F6},
    {"F7", SDL_SCANCODE_F7}, {"F8", SDL_SCANCODE_F8}, {"F9", SDL_SCANCODE_F9},
    {"F10", SDL_SCANCODE_F10}, {"F11", SDL_SCANCODE_F11}, {"F12", SDL_SCANCODE_F12},
    // Special
    {"Alt",       SDL_SCANCODE_LALT},
    {"Backspace", SDL_SCANCODE_BACKSPACE},
};
static const int kKeyCatalogCount = sizeof(kKeyCatalog) / sizeof(kKeyCatalog[0]);

// ============================================================================
// MARK: - SDL event injection
// ============================================================================

static Uint32 g_sdlWindowID = 0;

static void injectKey(SDL_Scancode scancode, BOOL pressed) {
    // Lazily resolve the SDL window ID on first use
    if (g_sdlWindowID == 0) {
        SDL_Window *w = SDL_GetGrabbedWindow();
        if (w) {
            g_sdlWindowID = SDL_GetWindowID(w);
        } else {
            // Single-window app: SDL window IDs start at 1
            g_sdlWindowID = 1;
        }
    }

    SDL_Event event;
    memset(&event, 0, sizeof(event));
    event.type              = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.timestamp     = SDL_GetTicks();
    event.key.windowID      = g_sdlWindowID;
    event.key.state         = pressed ? SDL_PRESSED : SDL_RELEASED;
    event.key.repeat        = 0;
    event.key.keysym.scancode = scancode;
    event.key.keysym.sym    = SDL_GetKeyFromScancode(scancode);
    event.key.keysym.mod    = KMOD_NONE;
    SDL_PushEvent(&event);
}

// ============================================================================
// MARK: - SDL event watcher (highlights buttons on hardware key events)
// ============================================================================

static NSString *const kSDLKeyEventNotification = @"TCSDLKeyEvent";

static int sdlKeyEventWatcher(void *userdata, SDL_Event *event) {
    if (event->type == SDL_KEYDOWN || event->type == SDL_KEYUP) {
        BOOL pressed = (event->type == SDL_KEYDOWN);
        SDL_Scancode sc = event->key.keysym.scancode;
        // Dispatch to main thread for UI updates
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kSDLKeyEventNotification
                              object:nil
                            userInfo:@{
                                @"scancode": @((int)sc),
                                @"pressed":  @(pressed),
                            }];
        });
    }
    return 1; // keep processing the event
}

static BOOL g_sdlKeyWatcherInstalled = NO;
static void installSDLKeyEventWatcher(void) {
    if (!g_sdlKeyWatcherInstalled) {
        SDL_AddEventWatch(sdlKeyEventWatcher, NULL);
        g_sdlKeyWatcherInstalled = YES;
    }
}

// ============================================================================
// MARK: - Character-to-scancode mapping (for system keyboard)
// ============================================================================

static SDL_Scancode scancodeForCharacter(unichar c) {
    if (c >= 'a' && c <= 'z') return (SDL_Scancode)(SDL_SCANCODE_A + (c - 'a'));
    if (c >= 'A' && c <= 'Z') return (SDL_Scancode)(SDL_SCANCODE_A + (c - 'A'));
    if (c >= '1' && c <= '9') return (SDL_Scancode)(SDL_SCANCODE_1 + (c - '1'));
    if (c == '0') return SDL_SCANCODE_0;
    switch (c) {
        case ' ':  return SDL_SCANCODE_SPACE;
        case '\n': return SDL_SCANCODE_RETURN;
        case '\t': return SDL_SCANCODE_TAB;
        case '-':  return SDL_SCANCODE_MINUS;
        case '=':  return SDL_SCANCODE_EQUALS;
        case '[':  return SDL_SCANCODE_LEFTBRACKET;
        case ']':  return SDL_SCANCODE_RIGHTBRACKET;
        case '\\': return SDL_SCANCODE_BACKSLASH;
        case ';':  return SDL_SCANCODE_SEMICOLON;
        case '\'': return SDL_SCANCODE_APOSTROPHE;
        case ',':  return SDL_SCANCODE_COMMA;
        case '.':  return SDL_SCANCODE_PERIOD;
        case '/':  return SDL_SCANCODE_SLASH;
        case '`':  return SDL_SCANCODE_GRAVE;
        default:   return SDL_SCANCODE_UNKNOWN;
    }
}

// ============================================================================
// MARK: - TCButton (individual action button)
// ============================================================================

@interface TCButton : UIView
@property (nonatomic) SDL_Scancode scancode;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) BOOL editing;
@property (nonatomic) BOOL active;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIView *deleteBadge;
@property (nonatomic, weak) UITouch *trackedTouch;
/// Position stored as fraction of superview size (for persistence / rotation)
@property (nonatomic) CGPoint relativeCenter;
// Resize animation state
@property (nonatomic, strong) CADisplayLink *resizeDisplayLink;
@property (nonatomic) CGFloat resizeFromSize;
@property (nonatomic) CGFloat resizeToTargetSize;
@property (nonatomic) CFTimeInterval resizeStartTime;
@property (nonatomic) CFTimeInterval resizeDuration;
@end

@implementation TCButton

- (instancetype)initWithLabel:(NSString *)label scancode:(SDL_Scancode)sc size:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0, 0, size, size)];
    if (self) {
        _scancode = sc;
        _label = [label copy];
        self.multipleTouchEnabled = NO;
        self.exclusiveTouch = NO;
        self.layer.cornerRadius = size / 2.0;
        self.layer.borderWidth  = 2.0;
        self.layer.borderColor  = [UIColor colorWithWhite:1.0 alpha:0.7].CGColor;
        self.backgroundColor    = [UIColor colorWithWhite:1.0 alpha:0.25];

        _textLabel = [[UILabel alloc] initWithFrame:self.bounds];
        _textLabel.text = label;
        _textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:1.0];
        _textLabel.font = [UIFont systemFontOfSize:(size < 50 ? 12 : 16) weight:UIFontWeightBold];
        _textLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_textLabel];

        // Delete badge (hidden until edit mode)
        _deleteBadge = [[UIView alloc] initWithFrame:CGRectMake(size - 18, -4, 22, 22)];
        _deleteBadge.backgroundColor = [UIColor systemRedColor];
        _deleteBadge.layer.cornerRadius = 11;
        _deleteBadge.hidden = YES;
        UILabel *x = [[UILabel alloc] initWithFrame:_deleteBadge.bounds];
        x.text = @"\u00D7"; // multiplication sign
        x.textColor = UIColor.whiteColor;
        x.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        x.textAlignment = NSTextAlignmentCenter;
        [_deleteBadge addSubview:x];
        [self addSubview:_deleteBadge];
    }
    return self;
}

- (void)setActive:(BOOL)active {
    _active = active;
    self.backgroundColor = active
        ? [UIColor colorWithWhite:1.0 alpha:0.50]
        : [UIColor colorWithWhite:1.0 alpha:0.25];
}

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    _deleteBadge.hidden = !editing;
    self.layer.borderColor = editing
        ? [UIColor systemYellowColor].CGColor
        : [UIColor colorWithWhite:1.0 alpha:0.7].CGColor;
}

// Circular hit area matching the round button shape, enlarged by 10pt
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat cx = self.bounds.size.width * 0.5;
    CGFloat cy = self.bounds.size.height * 0.5;
    CGFloat r = cx + 10; // button radius + 10pt padding
    CGFloat dx = point.x - cx, dy = point.y - cy;
    return (dx * dx + dy * dy) <= (r * r);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) return;
    UITouch *t = touches.anyObject;
    _trackedTouch = t;
    self.active = YES;
    injectKey(_scancode, YES);
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

- (void)resizeToSize:(CGFloat)newSize {
    [self resizeToSize:newSize animated:NO];
}

- (void)resizeToSize:(CGFloat)newSize animated:(BOOL)animated {
    // Cancel any in-flight resize
    [_resizeDisplayLink invalidate];
    _resizeDisplayLink = nil;

    if (!animated) {
        [self _applySize:newSize];
        return;
    }

    _resizeFromSize = self.bounds.size.width;
    _resizeToTargetSize = newSize;
    _resizeDuration = 0.18;
    _resizeStartTime = CACurrentMediaTime();

    _resizeDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_resizeTick:)];
    [_resizeDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// Critically damped spring approximation (fast settle, slight overshoot)
static CGFloat springCurve(CGFloat t) {
    // Attempt a spring-like bounce: overshoots slightly then settles
    CGFloat decay = expf(-5.0f * t);
    return 1.0f - decay * cosf(8.0f * t);
}

- (void)_resizeTick:(CADisplayLink *)dl {
    CFTimeInterval elapsed = CACurrentMediaTime() - _resizeStartTime;
    CGFloat t = (CGFloat)(elapsed / _resizeDuration);
    if (t >= 1.0) {
        t = 1.0;
        [_resizeDisplayLink invalidate];
        _resizeDisplayLink = nil;
    }
    CGFloat size = _resizeFromSize + (_resizeToTargetSize - _resizeFromSize) * springCurve(t);
    [self _applySize:size];
}

- (void)_applySize:(CGFloat)newSize {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGPoint c = self.center;
    self.bounds = CGRectMake(0, 0, newSize, newSize);
    self.center = c;
    self.layer.cornerRadius = newSize / 2.0;
    _textLabel.frame = self.bounds;
    _textLabel.font = [UIFont systemFontOfSize:(newSize < 50 ? 12 : 16) weight:UIFontWeightBold];
    _deleteBadge.frame = CGRectMake(newSize - 18, -4, 22, 22);
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
                                         scancode:(SDL_Scancode)[d[@"scancode"] intValue]
                                             size:size];
    b.relativeCenter = CGPointMake([d[@"rx"] floatValue], [d[@"ry"] floatValue]);
    return b;
}

@end

// ============================================================================
// MARK: - TCDPadView (directional pad)
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
@property (nonatomic, weak) UITouch *trackedTouch;
@end

@implementation TCDPadView

- (instancetype)initWithSize:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0, 0, size, size)];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = NO;
        self.exclusiveTouch = NO;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat s = rect.size.width;
    CGFloat armW = s * 0.36; // width of each arm
    CGFloat off = (s - armW) / 2.0;

    // Background circle
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.3 alpha:0.5].CGColor);
    CGContextFillEllipseInRect(ctx, rect);

    // Cross shape (union of horizontal + vertical bars)
    UIBezierPath *cross = [UIBezierPath bezierPath];
    // Vertical bar
    [cross appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(off, 4, armW, s - 8)
                                                cornerRadius:armW * 0.2]];
    // Horizontal bar
    [cross appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(4, off, s - 8, armW)
                                                cornerRadius:armW * 0.2]];

    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.20].CGColor);
    [cross fill];

    CGContextSetStrokeColorWithColor(ctx,
        _editing ? [UIColor systemYellowColor].CGColor
                 : [UIColor colorWithWhite:1.0 alpha:0.65].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    [cross stroke];

    // Direction highlights
    CGFloat qS = armW * 0.7;
    CGFloat cx = s / 2, cy = s / 2;
    struct { DPadDirection d; CGFloat x, y; const char *arrow; } dirs[] = {
        {DPadUp,    cx, cy - s * 0.28, "\u25B2"},
        {DPadDown,  cx, cy + s * 0.28, "\u25BC"},
        {DPadLeft,  cx - s * 0.28, cy, "\u25C0"},
        {DPadRight, cx + s * 0.28, cy, "\u25B6"},
    };
    for (int i = 0; i < 4; i++) {
        BOOL active = (_activeDirections & dirs[i].d) != 0;
        if (active) {
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.45].CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(dirs[i].x - qS/2, dirs[i].y - qS/2, qS, qS));
        }
        NSString *arrow = [NSString stringWithUTF8String:dirs[i].arrow];
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = NSTextAlignmentCenter;
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:16 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:(active ? 1.0 : 0.75)],
            NSParagraphStyleAttributeName: ps,
        };
        CGSize ts = [arrow sizeWithAttributes:attrs];
        [arrow drawInRect:CGRectMake(dirs[i].x - ts.width/2, dirs[i].y - ts.height/2, ts.width, ts.height)
           withAttributes:attrs];
    }
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

    CGFloat angle = atan2f(-dy, dx); // -dy because UIKit y is inverted
    DPadDirection dir = DPadNone;

    // 8 sectors of 45 degrees. Diagonals press two keys.
    // angle: 0=right, pi/2=up, pi=left, -pi/2=down
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

    // Release keys no longer held
    if ((old & DPadUp)    && !(newDir & DPadUp))    injectKey(SDL_SCANCODE_UP, NO);
    if ((old & DPadDown)  && !(newDir & DPadDown))  injectKey(SDL_SCANCODE_DOWN, NO);
    if ((old & DPadLeft)  && !(newDir & DPadLeft))  injectKey(SDL_SCANCODE_LEFT, NO);
    if ((old & DPadRight) && !(newDir & DPadRight)) injectKey(SDL_SCANCODE_RIGHT, NO);

    // Press newly held keys
    if (!(old & DPadUp)    && (newDir & DPadUp))    injectKey(SDL_SCANCODE_UP, YES);
    if (!(old & DPadDown)  && (newDir & DPadDown))  injectKey(SDL_SCANCODE_DOWN, YES);
    if (!(old & DPadLeft)  && (newDir & DPadLeft))  injectKey(SDL_SCANCODE_LEFT, YES);
    if (!(old & DPadRight) && (newDir & DPadRight)) injectKey(SDL_SCANCODE_RIGHT, YES);

    _activeDirections = newDir;
    [self setNeedsDisplay];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat r = self.bounds.size.width / 2 + 15; // extend hit area
    CGFloat cx = self.bounds.size.width / 2;
    CGFloat cy = self.bounds.size.height / 2;
    CGFloat dx = point.x - cx, dy = point.y - cy;
    return (dx*dx + dy*dy) <= r*r;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) return;
    UITouch *t = touches.anyObject;
    _trackedTouch = t;
    [self updateDirections:[self directionForTouch:t]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editing) return;
    UITouch *t = _trackedTouch;
    if (t && [touches containsObject:t]) {
        CGPoint p = [t locationInView:self];
        CGFloat r = self.bounds.size.width / 2 + 30;
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
// MARK: - TCDebugOverlay (FPS graph + engine info)
// ============================================================================

static const NSInteger kFPSSampleCount = 120;

@interface TCDebugOverlay : UIView
@property (nonatomic, assign) BOOL dragged;
@property (nonatomic, strong) UILabel *titleLabel;   // game title
@property (nonatomic, strong) UILabel *engineLabel;  // Ruby 1.8 · RGSS1
@property (nonatomic, strong) UILabel *statusLabel;  // Loading / Running / Error
@property (nonatomic, strong) UILabel *fpsLabel;     // FPS number
@property (nonatomic, strong) CAShapeLayer *graphLayer;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fpsSamples;
@property (nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation TCDebugOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.layer.cornerRadius = 10;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;

        _fpsSamples = [NSMutableArray arrayWithCapacity:kFPSSampleCount];

        // Drag gesture for repositioning
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
        [self addGestureRecognizer:pan];

        UIFont *smallFont = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
        UIColor *dimWhite = [UIColor colorWithWhite:1.0 alpha:0.7];

        // Game title (row 1)
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightBold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.text = @"—";
        [self addSubview:_titleLabel];

        // Engine info (row 2)
        _engineLabel = [[UILabel alloc] init];
        _engineLabel.font = smallFont;
        _engineLabel.textColor = dimWhite;
        _engineLabel.text = @"Ruby 1.8";
        [self addSubview:_engineLabel];

        // Status (row 3)
        _statusLabel = [[UILabel alloc] init];
        _statusLabel.font = smallFont;
        _statusLabel.textColor = [UIColor systemYellowColor];
        _statusLabel.text = @"Loading\u2026";
        [self addSubview:_statusLabel];

        // FPS number (row 4, left side)
        _fpsLabel = [[UILabel alloc] init];
        _fpsLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightBold];
        _fpsLabel.textColor = [UIColor systemGreenColor];
        _fpsLabel.text = @"-- FPS";
        [self addSubview:_fpsLabel];

        // Graph layer (row 4, right of FPS number)
        _graphLayer = [CAShapeLayer layer];
        _graphLayer.fillColor = nil;
        _graphLayer.lineWidth = 1.5;
        _graphLayer.strokeColor = [UIColor systemGreenColor].CGColor;
        [self.layer addSublayer:_graphLayer];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat y = 8;
    CGFloat rowH = 18;
    CGFloat pad = 10;

    _titleLabel.frame  = CGRectMake(pad, y, w - pad * 2, rowH);
    y += rowH + 2;
    _engineLabel.frame = CGRectMake(pad, y, w - pad * 2, rowH);
    y += rowH + 2;
    _statusLabel.frame = CGRectMake(pad, y, w - pad * 2, rowH);
    y += rowH + 4;

    // FPS row: number on left, graph fills the rest
    CGFloat fpsW = 72;
    CGFloat graphH = self.bounds.size.height - y - 6;
    if (graphH < 8) graphH = 8;
    _fpsLabel.frame   = CGRectMake(pad, y, fpsW, graphH);
    _graphLayer.frame = CGRectMake(pad + fpsW + 4, y, w - pad * 2 - fpsW - 4, graphH);
}

- (void)startUpdating {
    if (_displayLink) return;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(4, 15, 10);
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopUpdating {
    [_displayLink invalidate];
    _displayLink = nil;
}

- (void)tick:(CADisplayLink *)link {
    double fps = mkxp_getAverageFPS();
    if (fps < 0) fps = 0;
    if (fps > 999) fps = 999;

    [_fpsSamples addObject:@(fps)];
    while (_fpsSamples.count > kFPSSampleCount)
        [_fpsSamples removeObjectAtIndex:0];

    // Update engine info
    int rgss = mkxp_getRGSSVersion();
    if (rgss > 0) {
        _engineLabel.text = [NSString stringWithFormat:@"Ruby 1.8 \u00B7 RGSS%d", rgss];
    }

    // Update game title
    const char *title = mkxp_getGameTitle();
    if (title && title[0]) {
        _titleLabel.text = [NSString stringWithUTF8String:title];
    }

    // Update status
    if (!mkxp_isGameReady()) {
        _statusLabel.text = @"Loading\u2026";
        _statusLabel.textColor = [UIColor systemYellowColor];
    } else {
        _statusLabel.text = @"Running";
        _statusLabel.textColor = [UIColor systemGreenColor];
    }

    // Update FPS number
    int ifps = (int)round(fps);
    _fpsLabel.text = [NSString stringWithFormat:@"%d FPS", ifps];
    UIColor *fpsColor;
    if (ifps >= 55) {
        fpsColor = [UIColor systemGreenColor];
    } else if (ifps >= 30) {
        fpsColor = [UIColor systemYellowColor];
    } else {
        fpsColor = [UIColor systemRedColor];
    }
    _fpsLabel.textColor = fpsColor;
    _graphLayer.strokeColor = fpsColor.CGColor;

    [self updateGraph];
}

- (void)updateGraph {
    NSInteger count = _fpsSamples.count;
    if (count < 2) return;

    CGRect r = _graphLayer.bounds;
    CGFloat w = r.size.width;
    CGFloat h = r.size.height;
    CGFloat maxFPS = 70.0;

    UIBezierPath *path = [UIBezierPath bezierPath];
    for (NSInteger i = 0; i < count; i++) {
        CGFloat x = (CGFloat)i / (kFPSSampleCount - 1) * w;
        CGFloat val = _fpsSamples[i].doubleValue;
        CGFloat y = h - (val / maxFPS) * h;
        if (y < 0) y = 0;
        if (y > h) y = h;
        if (i == 0) [path moveToPoint:CGPointMake(x, y)];
        else        [path addLineToPoint:CGPointMake(x, y)];
    }
    _graphLayer.path = path.CGPath;
}

- (void)handleDrag:(UIPanGestureRecognizer *)pan {
    UIView *sv = self.superview;
    if (!sv) return;
    self.dragged = YES;
    CGPoint translation = [pan translationInView:sv];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x,
                                   self.center.y + translation.y);

    // Clamp within superview safe area
    UIEdgeInsets safe = sv.safeAreaInsets;
    CGFloat hw = self.bounds.size.width * 0.5;
    CGFloat hh = self.bounds.size.height * 0.5;
    newCenter.x = MAX(safe.left + hw, MIN(newCenter.x, sv.bounds.size.width - safe.right - hw));
    newCenter.y = MAX(safe.top + hh, MIN(newCenter.y, sv.bounds.size.height - safe.bottom - hh));

    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:sv];
}

- (void)dealloc {
    [self stopUpdating];
}

@end

// ============================================================================
// MARK: - TCKeyboardField (intercepts backspace)
// ============================================================================

@interface TCKeyboardField : UITextField
@end

@implementation TCKeyboardField

- (void)deleteBackward {
    injectKey(SDL_SCANCODE_BACKSPACE, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        injectKey(SDL_SCANCODE_BACKSPACE, NO);
    });
    // Don't call super — text field stays empty
}

// Keep the field visually empty
- (CGRect)caretRectForPosition:(UITextPosition *)position {
    return CGRectZero;
}

@end

// ============================================================================
// MARK: - TCLoadingView (spinner + "Loading...")
// ============================================================================

@interface TCLoadingView : UIView
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *label;
@end

@implementation TCLoadingView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.blackColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        _spinner.color = UIColor.whiteColor;
        [_spinner startAnimating];
        [self addSubview:_spinner];

        _label = [[UILabel alloc] init];
        _label.text = @"Loading\u2026";
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
        _label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _label.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_label];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat cx = self.bounds.size.width / 2;
    CGFloat cy = self.bounds.size.height / 2;
    _spinner.center = CGPointMake(cx, cy - 12);
    _label.frame = CGRectMake(0, cy + 20, self.bounds.size.width, 24);
}

- (void)dismiss {
    [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        self.alpha = 0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

@end

// ============================================================================
// MARK: - Keyboard accessory bar
// ============================================================================

// Forward-declare category so @selector references below resolve without warnings.
@interface UIView (TCAccKeyActions)
- (void)accKeyTap:(UIButton *)sender;
- (void)accKeyDown:(UIButton *)sender;
- (void)accKeyUp:(UIButton *)sender;
@end

static UIView *createKeyboardAccessoryView(void) {
    CGFloat barH = 80;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, barH)];
    bar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // Row 1: F1-F12 in a scroll view
    UIScrollView *fScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 2, 0, 36)];
    fScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    fScroll.showsHorizontalScrollIndicator = NO;
    [bar addSubview:fScroll];

    struct { const char *label; SDL_Scancode sc; } fKeys[] = {
        {"F1",SDL_SCANCODE_F1},{"F2",SDL_SCANCODE_F2},{"F3",SDL_SCANCODE_F3},
        {"F4",SDL_SCANCODE_F4},{"F5",SDL_SCANCODE_F5},{"F6",SDL_SCANCODE_F6},
        {"F7",SDL_SCANCODE_F7},{"F8",SDL_SCANCODE_F8},{"F9",SDL_SCANCODE_F9},
        {"F10",SDL_SCANCODE_F10},{"F11",SDL_SCANCODE_F11},{"F12",SDL_SCANCODE_F12},
    };
    CGFloat fX = 6;
    for (int i = 0; i < 12; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *title = [NSString stringWithUTF8String:fKeys[i].label];
        [btn setTitle:title forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
        btn.layer.cornerRadius = 5;
        CGFloat w = (i >= 9) ? 40 : 34; // wider for F10-F12
        btn.frame = CGRectMake(fX, 2, w, 32);
        btn.tag = fKeys[i].sc;
        // Tap key: down+up on touchUpInside
        [btn addTarget:bar action:@selector(accKeyTap:) forControlEvents:UIControlEventTouchUpInside];
        [fScroll addSubview:btn];
        fX += w + 4;
    }
    fScroll.contentSize = CGSizeMake(fX, 36);

    // Row 2: Esc, Tab, Ctrl, Shift, Alt, arrows, Enter
    UIScrollView *rScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 40, 0, 38)];
    rScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    rScroll.showsHorizontalScrollIndicator = NO;
    [bar addSubview:rScroll];

    struct { const char *label; SDL_Scancode sc; BOOL holdable; } row2[] = {
        {"Esc",  SDL_SCANCODE_ESCAPE, NO},
        {"Tab",  SDL_SCANCODE_TAB,    NO},
        {"Ctrl", SDL_SCANCODE_LCTRL,  YES},
        {"Shift",SDL_SCANCODE_LSHIFT, YES},
        {"Alt",  SDL_SCANCODE_LALT,   YES},
        {"\u2190",SDL_SCANCODE_LEFT,  YES},  // ←
        {"\u2191",SDL_SCANCODE_UP,    YES},  // ↑
        {"\u2193",SDL_SCANCODE_DOWN,  YES},  // ↓
        {"\u2192",SDL_SCANCODE_RIGHT, YES},  // →
        {"Enter",SDL_SCANCODE_RETURN, NO},
        {"Bksp", SDL_SCANCODE_BACKSPACE, NO},
    };
    CGFloat rX = 6;
    int row2Count = sizeof(row2) / sizeof(row2[0]);
    for (int i = 0; i < row2Count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *title = [NSString stringWithUTF8String:row2[i].label];
        [btn setTitle:title forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
        btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
        btn.layer.cornerRadius = 5;
        CGFloat w = 44;
        if (strlen(row2[i].label) <= 3 && row2[i].label[0] != '\\') w = 36; // narrower for arrows
        btn.frame = CGRectMake(rX, 2, w, 34);
        btn.tag = row2[i].sc;

        if (row2[i].holdable) {
            // Holdable: down on press, up on release
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
    SDL_Scancode sc = (SDL_Scancode)sender.tag;
    injectKey(sc, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        injectKey(sc, NO);
    });
}
- (void)accKeyDown:(UIButton *)sender {
    injectKey((SDL_Scancode)sender.tag, YES);
}
- (void)accKeyUp:(UIButton *)sender {
    injectKey((SDL_Scancode)sender.tag, NO);
}
@end

// ============================================================================
// MARK: - TouchControlsOverlay (main container + edit mode)
// ============================================================================

@interface TouchControlsOverlay () <UITextFieldDelegate>
@property (nonatomic, strong) TCDPadView *dpad;
@property (nonatomic, strong) NSMutableArray<TCButton *> *buttons;
@property (nonatomic) BOOL editMode;
@property (nonatomic, strong) UIButton *editToggle;
@property (nonatomic, strong) UIButton *addBtn;
@property (nonatomic, strong) UIButton *resetBtn;
@property (nonatomic, strong) UIView *editToolbar;
// drag tracking
@property (nonatomic, weak) UIView *dragTarget;
@property (nonatomic) CGPoint dragOffset;
@property (nonatomic) CGPoint dragStartPoint;
// debug overlay
@property (nonatomic, strong) TCDebugOverlay *debugOverlay;
@property (nonatomic, strong) UIButton *debugToggle;
// keyboard mode
@property (nonatomic) BOOL keyboardMode;
@property (nonatomic, strong) TCKeyboardField *keyboardTextField;
@property (nonatomic, strong) UIButton *keyboardToggle;
// hide controls
@property (nonatomic, strong) UIButton *hideToggle;
@property (nonatomic) BOOL controlsHidden;
// toolbar idle dimming
@property (nonatomic, strong) NSTimer *toolbarIdleTimer;
@property (nonatomic) BOOL toolbarDimmed;
// loading
@property (nonatomic, strong) TCLoadingView *loadingView;
@property (nonatomic, strong) NSTimer *loadingTimer;
@property (nonatomic) BOOL gameReady;
@end

@implementation TouchControlsOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _buttons = [NSMutableArray array];

        [self buildEditToolbar];
        [self buildDebugOverlay];
        [self buildKeyboardSupport];
        [self buildHideToggle];

        // Load saved layout or create defaults
        if (![self loadLayout]) {
            [self createDefaultLayout];
        }

        // Start with controls hidden (loading screen will be on top)
        [self setControlsHidden:YES animated:NO];

        // Show loading screen
        _loadingView = [[TCLoadingView alloc] initWithFrame:self.bounds];
        [self addSubview:_loadingView];

        // Poll for game readiness
        _loadingTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                         target:self
                                                       selector:@selector(checkGameReady)
                                                       userInfo:nil
                                                        repeats:YES];
    }
    return self;
}

- (void)checkGameReady {
    if (mkxp_isGameReady()) {
        [_loadingTimer invalidate];
        _loadingTimer = nil;
        _gameReady = YES;

        // Dismiss loading screen and show controls
        [_loadingView dismiss];
        _loadingView = nil;
        [self setControlsHidden:NO animated:YES];
        [self resetToolbarIdleTimer];
    }
}

- (void)setControlsHidden:(BOOL)hidden animated:(BOOL)animated {
    CGFloat alpha = hidden ? 0.0 : 1.0;
    void (^block)(void) = ^{
        self.dpad.alpha = alpha;
        for (TCButton *b in self.buttons) b.alpha = alpha;
        self.editToggle.alpha = alpha;
        self.debugToggle.alpha = alpha;
        self.keyboardToggle.alpha = alpha;
        self.hideToggle.alpha = alpha;
    };
    if (animated) {
        [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:block completion:nil];
    } else {
        block();
    }
}

static const NSTimeInterval kToolbarIdleDelay = 3.0;

- (void)resetToolbarIdleTimer {
    [_toolbarIdleTimer invalidate];
    if (_toolbarDimmed) {
        _toolbarDimmed = NO;
        [self applyToolbarAlpha:1.0];
    }
    _toolbarIdleTimer = [NSTimer scheduledTimerWithTimeInterval:kToolbarIdleDelay
                                                        target:self
                                                      selector:@selector(dimToolbarButtons)
                                                      userInfo:nil
                                                       repeats:NO];
}

- (void)dimToolbarButtons {
    if (_editMode || _controlsHidden) return; // don't dim during edit or when hidden
    _toolbarDimmed = YES;
    [UIView animateWithDuration:0.6 delay:0 usingSpringWithDamping:1.0 initialSpringVelocity:0 options:0 animations:^{
        [self applyToolbarAlpha:0.5];
    } completion:nil];
}

- (void)applyToolbarAlpha:(CGFloat)alpha {
    _editToggle.alpha = alpha;
    _debugToggle.alpha = alpha;
    _keyboardToggle.alpha = alpha;
    _hideToggle.alpha = alpha;
}

// Pass through touches that don't hit any control
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_editMode) {
        UIView *hit = [super hitTest:point withEvent:event];
        if (!hit) return nil;
        // Let toolbar buttons handle their own UIControlEvent touches
        if ([hit isDescendantOfView:_editToolbar] || hit == _editToolbar) return hit;
        // Everything else -> overlay handles drag/delete
        return self;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    // Reset idle timer when any toolbar button is tapped
    if (hit == _editToggle || hit == _debugToggle || hit == _keyboardToggle || hit == _hideToggle) {
        [self resetToolbarIdleTimer];
    }
    return (hit == self) ? nil : hit;
}

// ============================================================================
// MARK: Edit toolbar
// ============================================================================

- (void)buildEditToolbar {
    _editToolbar = [[UIView alloc] init];
    _editToolbar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    _editToolbar.layer.cornerRadius = 12;
    _editToolbar.hidden = YES;
    [self addSubview:_editToolbar];

    _addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_addBtn setTitle:@"+ Add" forState:UIControlStateNormal];
    [_addBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _addBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_addBtn addTarget:self action:@selector(onAddButton) forControlEvents:UIControlEventTouchUpInside];

    _resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_resetBtn setTitle:@"Reset" forState:UIControlStateNormal];
    [_resetBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
    _resetBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_resetBtn addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];

    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [doneBtn setTitle:@"Done" forState:UIControlStateNormal];
    [doneBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
    doneBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [doneBtn addTarget:self action:@selector(toggleEditMode) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_addBtn, _resetBtn, doneBtn]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_editToolbar addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:_editToolbar.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:_editToolbar.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:_editToolbar.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:_editToolbar.bottomAnchor constant:-6],
    ]];

    // Edit toggle button (gear icon, always visible)
    _editToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    [_editToggle setImage:[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg]
                 forState:UIControlStateNormal];
    _editToggle.tintColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    _editToggle.backgroundColor = [UIColor colorWithWhite:0.3 alpha:0.5];
    _editToggle.layer.cornerRadius = kSmallButtonSize / 2;
    [_editToggle addTarget:self action:@selector(toggleEditMode) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_editToggle];
}

// ============================================================================
// MARK: Debug overlay
// ============================================================================

- (void)buildDebugOverlay {
    _debugOverlay = [[TCDebugOverlay alloc] initWithFrame:CGRectMake(0, 0, 260, 120)];
    _debugOverlay.hidden = YES;
    [self addSubview:_debugOverlay];

    _debugToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    [_debugToggle setImage:[UIImage systemImageNamed:@"chart.line.uptrend.xyaxis" withConfiguration:cfg]
                  forState:UIControlStateNormal];
    _debugToggle.tintColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    _debugToggle.backgroundColor = [UIColor colorWithWhite:0.3 alpha:0.5];
    _debugToggle.layer.cornerRadius = kSmallButtonSize / 2;
    [_debugToggle addTarget:self action:@selector(toggleDebug) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_debugToggle];
}

- (void)toggleDebug {
    BOOL show = _debugOverlay.hidden;
    _debugOverlay.hidden = !show;
    if (show) {
        [_debugOverlay startUpdating];
    } else {
        [_debugOverlay stopUpdating];
    }
}

// ============================================================================
// MARK: Keyboard support
// ============================================================================

- (void)buildKeyboardSupport {
    _keyboardTextField = [[TCKeyboardField alloc] initWithFrame:CGRectZero];
    _keyboardTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    _keyboardTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _keyboardTextField.spellCheckingType = UITextSpellCheckingTypeNo;
    _keyboardTextField.smartQuotesType = UITextSmartQuotesTypeNo;
    _keyboardTextField.smartDashesType = UITextSmartDashesTypeNo;
    _keyboardTextField.keyboardAppearance = UIKeyboardAppearanceDark;
    _keyboardTextField.returnKeyType = UIReturnKeyDefault;
    _keyboardTextField.delegate = self;
    _keyboardTextField.inputAccessoryView = createKeyboardAccessoryView();
    // Keep a space in the field so backspace works
    _keyboardTextField.text = @" ";
    [self addSubview:_keyboardTextField];

    _keyboardToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    [_keyboardToggle setImage:[UIImage systemImageNamed:@"keyboard" withConfiguration:cfg]
                     forState:UIControlStateNormal];
    _keyboardToggle.tintColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    _keyboardToggle.backgroundColor = [UIColor colorWithWhite:0.3 alpha:0.5];
    _keyboardToggle.layer.cornerRadius = kSmallButtonSize / 2;
    [_keyboardToggle addTarget:self action:@selector(toggleKeyboard) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_keyboardToggle];

    // Watch for software keyboard appearing — hide game buttons when it does
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardDidShow:)
                                                 name:UIKeyboardDidShowNotification
                                               object:nil];

    // Watch for keyboard dismiss by external means
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    // Watch for hardware key events to highlight matching game buttons
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSDLKeyEvent:)
                                                 name:kSDLKeyEventNotification
                                               object:nil];
    installSDLKeyEventWatcher();
}

- (void)buildHideToggle {
    _hideToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    [_hideToggle setImage:[UIImage systemImageNamed:@"eye.fill" withConfiguration:cfg]
                 forState:UIControlStateNormal];
    _hideToggle.tintColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    _hideToggle.backgroundColor = [UIColor colorWithWhite:0.3 alpha:0.5];
    _hideToggle.layer.cornerRadius = kSmallButtonSize / 2;
    [_hideToggle addTarget:self action:@selector(toggleHideControls) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_hideToggle];
}

- (void)toggleHideControls {
    _controlsHidden = !_controlsHidden;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    NSString *icon = _controlsHidden ? @"eye.slash.fill" : @"eye.fill";
    [_hideToggle setImage:[UIImage systemImageNamed:icon withConfiguration:cfg]
                 forState:UIControlStateNormal];

    CGFloat alpha = _controlsHidden ? 0.0 : 1.0;
    [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        self.dpad.alpha = alpha;
        for (TCButton *b in self.buttons) b.alpha = alpha;
        self.editToggle.alpha = alpha;
        self.debugToggle.alpha = alpha;
        self.keyboardToggle.alpha = alpha;
    } completion:nil];
}

- (void)toggleKeyboard {
    if (_keyboardMode) {
        // Switch to game controls
        _keyboardMode = NO;
        [_keyboardTextField resignFirstResponder];
        // Restore buttons if they were hidden by the software keyboard
        [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
            self.dpad.alpha = 1;
            for (TCButton *b in self.buttons) b.alpha = 1;
        } completion:nil];
        _keyboardToggle.backgroundColor = [UIColor colorWithWhite:0.3 alpha:0.5];
    } else {
        // Switch to keyboard — keep game buttons visible initially.
        // They'll be hidden only if the software keyboard actually appears
        // (UIKeyboardDidShowNotification). On Simulator or iPad with hardware
        // keyboard, the software keyboard won't appear, so buttons stay visible
        // and highlight on hardware key presses.
        _keyboardMode = YES;
        [self.window makeKeyWindow];
        [_keyboardTextField becomeFirstResponder];
        _keyboardToggle.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.7];
    }
}

- (void)keyboardDidShow:(NSNotification *)note {
    if (_keyboardMode) {
        // Software keyboard appeared — hide game buttons to make room
        [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
            self.dpad.alpha = 0;
            for (TCButton *b in self.buttons) b.alpha = 0;
        } completion:nil];
    }
}

- (void)keyboardWillHide:(NSNotification *)note {
    if (_keyboardMode) {
        _keyboardMode = NO;
        [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
            self.dpad.alpha = 1;
            for (TCButton *b in self.buttons) b.alpha = 1;
        } completion:nil];
        _keyboardToggle.backgroundColor = [UIColor colorWithWhite:0.3 alpha:0.5];
    }
}

- (void)handleSDLKeyEvent:(NSNotification *)note {
    SDL_Scancode sc = (SDL_Scancode)[note.userInfo[@"scancode"] intValue];
    BOOL pressed = [note.userInfo[@"pressed"] boolValue];

    for (TCButton *b in _buttons) {
        if (b.scancode == sc) {
            b.active = pressed;
        }
    }

    // Also highlight D-pad directions (set visually only, don't re-inject keys)
    if (_dpad) {
        DPadDirection dir = DPadNone;
        if (sc == SDL_SCANCODE_UP)    dir = DPadUp;
        if (sc == SDL_SCANCODE_DOWN)  dir = DPadDown;
        if (sc == SDL_SCANCODE_LEFT)  dir = DPadLeft;
        if (sc == SDL_SCANCODE_RIGHT) dir = DPadRight;
        if (dir != DPadNone) {
            DPadDirection cur = _dpad.activeDirections;
            if (pressed)
                _dpad.activeDirections = cur | dir;
            else
                _dpad.activeDirections = cur & ~dir;
            [_dpad setNeedsDisplay];
        }
    }
}

// UITextFieldDelegate
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range
                                                      replacementString:(NSString *)string {
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        BOOL isUpper = (c >= 'A' && c <= 'Z');
        SDL_Scancode sc = scancodeForCharacter(c);
        if (sc == SDL_SCANCODE_UNKNOWN) continue;

        if (isUpper) injectKey(SDL_SCANCODE_LSHIFT, YES);
        injectKey(sc, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            injectKey(sc, NO);
            if (isUpper) injectKey(SDL_SCANCODE_LSHIFT, NO);
        });
    }
    // Keep a space in the field so backspace always works
    textField.text = @" ";
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    injectKey(SDL_SCANCODE_RETURN, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        injectKey(SDL_SCANCODE_RETURN, NO);
    });
    return NO;
}

// ============================================================================
// MARK: Layout
// ============================================================================

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize sz = self.bounds.size;
    UIEdgeInsets safe = self.safeAreaInsets;

    // Top-right button row: [hide] [keyboard] [debug] [gear]
    // Position inside safe area so buttons aren't clipped by notch or rounded corners
    CGFloat btnY = safe.top + 4;
    CGFloat btnX = sz.width - safe.right - 4;

    // Hide toggle — rightmost (always visible)
    btnX -= kSmallButtonSize;
    _hideToggle.frame = CGRectMake(btnX, btnY, kSmallButtonSize, kSmallButtonSize);

    // Gear (edit toggle)
    btnX -= (kSmallButtonSize + 8);
    _editToggle.frame = CGRectMake(btnX, btnY, kSmallButtonSize, kSmallButtonSize);

    // Debug toggle
    btnX -= (kSmallButtonSize + 8);
    _debugToggle.frame = CGRectMake(btnX, btnY, kSmallButtonSize, kSmallButtonSize);

    // Keyboard toggle
    btnX -= (kSmallButtonSize + 8);
    _keyboardToggle.frame = CGRectMake(btnX, btnY, kSmallButtonSize, kSmallButtonSize);

    // Edit toolbar: top center of screen, inside safe area
    CGFloat tbW = 260, tbH = 40;
    _editToolbar.frame = CGRectMake((sz.width - tbW) / 2, safe.top + 4, tbW, tbH);

    // Debug overlay: top-left corner inside safe area (unless user dragged it)
    if (!_debugOverlay.dragged) {
        _debugOverlay.frame = CGRectMake(safe.left + 4, safe.top + 4, 220, 100);
    }

    // Ensure toolbar buttons are always on top of everything
    [self bringSubviewToFront:_debugOverlay];
    [self bringSubviewToFront:_editToolbar];
    [self bringSubviewToFront:_keyboardToggle];
    [self bringSubviewToFront:_debugToggle];
    [self bringSubviewToFront:_editToggle];
    [self bringSubviewToFront:_hideToggle];

    // Loading view
    _loadingView.frame = self.bounds;

    // Position controls from their relative centers
    [self applyRelativePositions];
}

- (void)applyRelativePositions {
    CGSize sz = self.bounds.size;
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat minX = safe.left;
    CGFloat minY = safe.top;
    CGFloat maxX = sz.width - safe.right;
    CGFloat maxY = sz.height - safe.bottom;

    if (_dpad) {
        CGFloat hw = _dpad.bounds.size.width * 0.5;
        CGFloat hh = _dpad.bounds.size.height * 0.5;
        CGFloat cx = MAX(minX + hw, MIN(_dpad.relativeCenter.x * sz.width, maxX - hw));
        CGFloat cy = MAX(minY + hh, MIN(_dpad.relativeCenter.y * sz.height, maxY - hh));
        _dpad.center = CGPointMake(cx, cy);
    }
    for (TCButton *b in _buttons) {
        CGFloat hw = b.bounds.size.width * 0.5;
        CGFloat hh = b.bounds.size.height * 0.5;
        CGFloat bp = _editMode ? 6 : 0; // badge overflow padding
        CGFloat cx = MAX(minX + hw, MIN(b.relativeCenter.x * sz.width, maxX - hw - bp));
        CGFloat cy = MAX(minY + hh + bp, MIN(b.relativeCenter.y * sz.height, maxY - hh));
        b.center = CGPointMake(cx, cy);
    }
}

- (void)updateRelativePositions {
    CGSize sz = self.bounds.size;
    if (sz.width < 1 || sz.height < 1) return;

    if (_dpad) {
        _dpad.relativeCenter = CGPointMake(_dpad.center.x / sz.width,
                                           _dpad.center.y / sz.height);
    }
    for (TCButton *b in _buttons) {
        b.relativeCenter = CGPointMake(b.center.x / sz.width,
                                       b.center.y / sz.height);
    }
}

// ============================================================================
// MARK: Default layout
// ============================================================================

- (void)createDefaultLayout {
    [self createDefaultLayoutAnimated:NO];
}

- (void)createDefaultLayoutAnimated:(BOOL)animated {
    // Default definitions
    struct DefEntry { const char *label; SDL_Scancode sc; CGFloat rx, ry, size; };
    DefEntry defs[] = {
        {"A",     SDL_SCANCODE_RETURN,  0.90, 0.75, kButtonSize},
        {"B",     SDL_SCANCODE_ESCAPE,  0.80, 0.68, kButtonSize},
        {"Shift", SDL_SCANCODE_LSHIFT,  0.72, 0.80, kButtonSize - 6},
        {"Esc",   SDL_SCANCODE_ESCAPE,  0.92, 0.58, kSmallButtonSize},
    };
    int defCount = 4;
    CGPoint defaultDpadCenter = CGPointMake(0.13, 0.72);

    if (!animated) {
        // Non-animated: just replace everything instantly
        [_dpad removeFromSuperview];
        for (TCButton *b in _buttons) [b removeFromSuperview];
        [_buttons removeAllObjects];

        _dpad = [[TCDPadView alloc] initWithSize:kDPadSize];
        _dpad.relativeCenter = defaultDpadCenter;
        [self insertSubview:_dpad atIndex:0];

        for (int i = 0; i < defCount; i++) {
            TCButton *b = [[TCButton alloc] initWithLabel:[NSString stringWithUTF8String:defs[i].label]
                                                 scancode:defs[i].sc
                                                     size:defs[i].size];
            b.relativeCenter = CGPointMake(defs[i].rx, defs[i].ry);
            [_buttons addObject:b];
            [self insertSubview:b atIndex:0];
        }
        [self applyRelativePositions];
        return;
    }

    // ---- Animated reset ----
    // 1. Identify old buttons to remove, buttons to keep/move, and new buttons to add
    TCDPadView *oldDpad = _dpad;
    NSArray<TCButton *> *oldButtons = [_buttons copy];

    // Build the new set of buttons
    NSMutableArray<TCButton *> *newButtons = [NSMutableArray array];
    for (int i = 0; i < defCount; i++) {
        TCButton *b = [[TCButton alloc] initWithLabel:[NSString stringWithUTF8String:defs[i].label]
                                             scancode:defs[i].sc
                                                 size:defs[i].size];
        b.relativeCenter = CGPointMake(defs[i].rx, defs[i].ry);
        [newButtons addObject:b];
    }

    // 2. Fade out old buttons that don't match any new button (by label + scancode)
    NSMutableArray<TCButton *> *toRemove = [NSMutableArray array];
    for (TCButton *old in oldButtons) {
        [toRemove addObject:old];
    }

    // 3. Create new D-pad if needed
    TCDPadView *newDpad = [[TCDPadView alloc] initWithSize:kDPadSize];
    newDpad.relativeCenter = defaultDpadCenter;

    // Replace state immediately so layout methods work
    _dpad = newDpad;
    [_buttons removeAllObjects];
    [_buttons addObjectsFromArray:newButtons];

    // 4. Add new views with alpha 0, positioned at their targets
    [self insertSubview:newDpad atIndex:0];
    for (TCButton *b in newButtons) {
        [self insertSubview:b atIndex:0];
    }
    [self applyRelativePositions];

    // Start new controls invisible and scaled down
    newDpad.alpha = 0;
    newDpad.transform = CGAffineTransformMakeScale(0.5, 0.5);
    for (TCButton *b in newButtons) {
        b.alpha = 0;
        b.transform = CGAffineTransformMakeScale(0.3, 0.3);
    }

    // 5. Animate: fade out old, fade in new
    [UIView animateWithDuration:0.15 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        // Fade out + shrink old controls
        oldDpad.alpha = 0;
        oldDpad.transform = CGAffineTransformMakeScale(0.3, 0.3);
        for (TCButton *b in toRemove) {
            b.alpha = 0;
            b.transform = CGAffineTransformMakeScale(0.3, 0.3);
        }
    } completion:^(BOOL finished) {
        // Remove old views
        [oldDpad removeFromSuperview];
        for (TCButton *b in toRemove) [b removeFromSuperview];

        // Animate in new controls
        [UIView animateWithDuration:0.18 delay:0
              usingSpringWithDamping:0.7
               initialSpringVelocity:0
                             options:0
                          animations:^{
            newDpad.alpha = 1;
            newDpad.transform = CGAffineTransformIdentity;
            for (TCButton *b in newButtons) {
                b.alpha = 1;
                b.transform = CGAffineTransformIdentity;
            }
        } completion:nil];
    }];
}

// ============================================================================
// MARK: Edit mode
// ============================================================================

- (void)toggleEditMode {
    _editMode = !_editMode;
    _editToolbar.hidden = !_editMode;
    _editToggle.hidden = _editMode; // hide gear when toolbar is showing
    _debugToggle.hidden = _editMode;
    _keyboardToggle.hidden = _editMode;
    _hideToggle.hidden = _editMode;
    _dpad.editing = _editMode;
    for (TCButton *b in _buttons) {
        b.editing = _editMode;
    }

    // Exit keyboard mode when entering edit mode
    if (_editMode && _keyboardMode) {
        [self toggleKeyboard];
    }

    if (!_editMode) {
        [self saveLayout];
        [self resetToolbarIdleTimer];
    }
}

// Dragging in edit mode
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_editMode) return;
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];

    // Check if touching a draggable control
    if (CGRectContainsPoint(_dpad.frame, p)) {
        _dragTarget = _dpad;
        _dragOffset = CGPointMake(p.x - _dpad.center.x, p.y - _dpad.center.y);
        _dragStartPoint = p;
        return;
    }
    for (TCButton *b in _buttons) {
        if (CGRectContainsPoint(CGRectInset(b.frame, -10, -10), p)) {
            _dragTarget = b;
            _dragOffset = CGPointMake(p.x - b.center.x, p.y - b.center.y);
            _dragStartPoint = p;
            return;
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_editMode || !_dragTarget) return;
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    CGPoint newCenter = CGPointMake(p.x - _dragOffset.x, p.y - _dragOffset.y);

    // Clamp within safe area so controls can't be dragged under notch or rounded corners.
    // Extra padding accounts for the delete badge that protrudes above and to the right.
    CGFloat hw = _dragTarget.bounds.size.width * 0.5;
    CGFloat hh = _dragTarget.bounds.size.height * 0.5;
    CGFloat badgePad = _editMode ? 6 : 0; // delete badge overflows ~4px; add margin
    UIEdgeInsets safe = self.safeAreaInsets;
    newCenter.x = MAX(safe.left + hw, MIN(newCenter.x, self.bounds.size.width - safe.right - hw - badgePad));
    newCenter.y = MAX(safe.top + hh + badgePad, MIN(newCenter.y, self.bounds.size.height - safe.bottom - hh));

    _dragTarget.center = newCenter;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editMode && _dragTarget) {
        UITouch *t = touches.anyObject;
        CGPoint p = [t locationInView:self];
        CGFloat moved = hypot(p.x - _dragStartPoint.x, p.y - _dragStartPoint.y);

        if (moved < 5 && [_dragTarget isKindOfClass:[TCButton class]]) {
            TCButton *btn = (TCButton *)_dragTarget;
            CGPoint inBtn = [t locationInView:btn];
            if (!btn.deleteBadge.hidden &&
                CGRectContainsPoint(CGRectInset(btn.deleteBadge.frame, -2, -2), inBtn)) {
                [self deleteButton:btn];
            } else {
                // Tap on button body -> show edit menu
                [self showEditMenuForButton:btn];
            }
        }
        [self updateRelativePositions];
        _dragTarget = nil;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _dragTarget = nil;
    [self updateRelativePositions];
}

// ============================================================================
// MARK: Button Edit Menu
// ============================================================================

- (void)showEditMenuForButton:(TCButton *)btn {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Edit Button"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    // --- Change display label ---
    [ac addAction:[UIAlertAction actionWithTitle:@"Change Label"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [self showLabelEditorForButton:btn];
    }]];

    // --- Change emulated key ---
    [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Change Key (now: %@)", [self scancodeDisplayName:btn.scancode]]
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [self showKeyPickerForButton:btn];
    }]];

    // --- Change size ---
    [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Change Size (now: %.0f)", btn.bounds.size.width]
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [self showSizePickerForButton:btn];
    }]];

    // --- Delete ---
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        [self deleteButton:btn];
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];

    ac.popoverPresentationController.sourceView = btn;
    ac.popoverPresentationController.sourceRect = btn.bounds;

    [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)showLabelEditorForButton:(TCButton *)btn {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Button Label"
                                                               message:@"Enter the text to display on this button"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = btn.label;
        tf.placeholder = @"Label";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        NSString *newLabel = ac.textFields.firstObject.text;
        if (newLabel.length > 0) {
            [btn updateLabel:newLabel];
        }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)showKeyPickerForButton:(TCButton *)btn {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Emulated Key"
                                                               message:@"Select which key this button sends"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    for (int i = 0; i < kKeyCatalogCount; i++) {
        NSString *entryLabel = [NSString stringWithUTF8String:kKeyCatalog[i].label];
        SDL_Scancode sc = kKeyCatalog[i].scancode;
        NSString *title = entryLabel;
        if (sc == btn.scancode) {
            title = [NSString stringWithFormat:@"\u2713 %@", entryLabel]; // checkmark for current
        }
        [ac addAction:[UIAlertAction actionWithTitle:title
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            btn.scancode = sc;
        }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];

    ac.popoverPresentationController.sourceView = btn;
    ac.popoverPresentationController.sourceRect = btn.bounds;

    [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)showSizePickerForButton:(TCButton *)btn {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Button Size"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    struct { const char *name; CGFloat size; } sizes[] = {
        {"Small (38)",   38},
        {"Medium (50)",  50},
        {"Default (56)", 56},
        {"Large (68)",   68},
        {"XL (80)",      80},
    };
    int count = sizeof(sizes) / sizeof(sizes[0]);

    for (int i = 0; i < count; i++) {
        CGFloat sz = sizes[i].size;
        NSString *title = [NSString stringWithUTF8String:sizes[i].name];
        if ((int)sz == (int)btn.bounds.size.width) {
            title = [NSString stringWithFormat:@"\u2713 %@", title];
        }
        [ac addAction:[UIAlertAction actionWithTitle:title
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [btn resizeToSize:sz animated:YES];
        }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];

    ac.popoverPresentationController.sourceView = btn;
    ac.popoverPresentationController.sourceRect = btn.bounds;

    [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (NSString *)scancodeDisplayName:(SDL_Scancode)sc {
    for (int i = 0; i < kKeyCatalogCount; i++) {
        if (kKeyCatalog[i].scancode == sc) {
            return [NSString stringWithUTF8String:kKeyCatalog[i].label];
        }
    }
    return [NSString stringWithFormat:@"Key %d", (int)sc];
}

// ============================================================================
// MARK: Add / Delete / Reset
// ============================================================================

- (void)onAddButton {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Add Button"
                                                               message:@"Select a key to map"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    for (int i = 0; i < kKeyCatalogCount; i++) {
        NSString *label = [NSString stringWithUTF8String:kKeyCatalog[i].label];
        SDL_Scancode sc = kKeyCatalog[i].scancode;
        [ac addAction:[UIAlertAction actionWithTitle:label
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [self addButtonWithLabel:label scancode:sc];
        }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];

    // For iPad popover
    ac.popoverPresentationController.sourceView = _addBtn;
    ac.popoverPresentationController.sourceRect = _addBtn.bounds;

    UIViewController *vc = self.window.rootViewController;
    [vc presentViewController:ac animated:YES completion:nil];
}

- (void)addButtonWithLabel:(NSString *)label scancode:(SDL_Scancode)sc {
    // Short display label (strip parenthetical descriptions)
    NSString *displayLabel = label;
    NSRange paren = [label rangeOfString:@" ("];
    if (paren.location != NSNotFound)
        displayLabel = [label substringToIndex:paren.location];

    TCButton *b = [[TCButton alloc] initWithLabel:displayLabel scancode:sc size:kButtonSize];
    // Place near center of screen
    b.relativeCenter = CGPointMake(0.5, 0.5);
    b.editing = YES;
    [_buttons addObject:b];
    [self insertSubview:b atIndex:0];
    [self applyRelativePositions];
}

- (void)deleteButton:(TCButton *)btn {
    [UIView animateWithDuration:0.15 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        btn.transform = CGAffineTransformMakeScale(0.1, 0.1);
        btn.alpha = 0;
    } completion:^(BOOL finished) {
        [btn removeFromSuperview];
        [self.buttons removeObject:btn];
    }];
}

- (void)onReset {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Reset Controls"
                                                                message:@"Restore default layout?"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self createDefaultLayoutAnimated:YES];
        // Set editing state after a short delay so new views exist
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.dpad.editing = YES;
            for (TCButton *b in self.buttons) b.editing = YES;
        });
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
}

// ============================================================================
// MARK: Persistence
// ============================================================================

- (void)saveLayout {
    [self updateRelativePositions];
    NSMutableArray *btnDicts = [NSMutableArray array];
    for (TCButton *b in _buttons) {
        [btnDicts addObject:[b toDict]];
    }
    NSDictionary *layout = @{
        @"dpad":    [_dpad toDict],
        @"buttons": btnDicts,
    };
    [[NSUserDefaults standardUserDefaults] setObject:layout forKey:kSavedLayoutKey];
}

- (BOOL)loadLayout {
    NSDictionary *layout = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSavedLayoutKey];
    if (!layout) return NO;

    // Remove existing
    [_dpad removeFromSuperview];
    for (TCButton *b in _buttons) [b removeFromSuperview];
    [_buttons removeAllObjects];

    // D-Pad
    NSDictionary *dd = layout[@"dpad"];
    CGFloat dpadSize = [dd[@"size"] floatValue] ?: kDPadSize;
    _dpad = [[TCDPadView alloc] initWithSize:dpadSize];
    _dpad.relativeCenter = CGPointMake([dd[@"rx"] floatValue], [dd[@"ry"] floatValue]);
    [self insertSubview:_dpad atIndex:0];

    // Buttons
    NSArray *btnDicts = layout[@"buttons"];
    for (NSDictionary *d in btnDicts) {
        TCButton *b = [TCButton fromDict:d];
        [_buttons addObject:b];
        [self insertSubview:b atIndex:0];
    }

    [self applyRelativePositions];
    return YES;
}

@end

// ============================================================================
// MARK: - Transparent overlay window (guarantees touches above SDL)
// ============================================================================

/// A separate UIWindow that floats above SDL's window.  Touches that don't
/// land on any control are passed through to the SDL window underneath.
@interface TouchControlsWindow : UIWindow
@property (nonatomic) BOOL allowKeyWindow;
@end

@implementation TouchControlsWindow

- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene {
    self = [super initWithWindowScene:windowScene];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.windowLevel = UIWindowLevelNormal + 1; // above SDL window
        self.userInteractionEnabled = YES;
    }
    return self;
}

/// Only allow becoming key window when keyboard mode needs it.
- (BOOL)canBecomeKeyWindow {
    return _allowKeyWindow;
}

/// Return nil when no control is hit so the touch falls through to SDL's window.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // If hit is the window itself or its root VC's bare view, pass through
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

@end

// ============================================================================
// MARK: - Passthrough root view controller
// ============================================================================

@interface TouchControlsViewController : UIViewController
@end

@implementation TouchControlsViewController

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end

// ============================================================================
// MARK: - Auto-installation (no engine code changes required)
// ============================================================================

/// Helper class that registers for UIWindow notifications at load time.
/// When SDL's UIWindow becomes key, a separate overlay window is created
/// on top, containing the touch controls.
@interface TouchControlsLoader : NSObject
@end

static TouchControlsWindow *g_overlayWindow = nil;
static UIWindow *g_sdlWindow = nil;

@implementation TouchControlsLoader

+ (void)load {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        UIWindow *sdlWindow = (UIWindow *)note.object;
        if (!sdlWindow) return;
        // Don't react to our own overlay window
        if ([sdlWindow isKindOfClass:[TouchControlsWindow class]]) return;
        // Guard: don't create twice
        if (g_overlayWindow) return;

        g_sdlWindow = sdlWindow;

        // Create overlay window on the same window scene.
        // With UILaunchScreen in Info.plist, iOS uses the native screen
        // resolution instead of compatibility mode, so SDL's window scene
        // already covers the full physical display.
        g_overlayWindow = [[TouchControlsWindow alloc] initWithWindowScene:sdlWindow.windowScene];

        // Root VC with a transparent view
        TouchControlsViewController *vc = [[TouchControlsViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        g_overlayWindow.rootViewController = vc;

        // Add the touch controls overlay filling the root VC's view
        TouchControlsOverlay *overlay =
            [[TouchControlsOverlay alloc] initWithFrame:vc.view.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view addSubview:overlay];

        // Show the window without stealing key status from SDL
        g_overlayWindow.hidden = NO;
        // SDL must remain key window for proper event handling
        [sdlWindow makeKeyWindow];
    }];
}

@end
