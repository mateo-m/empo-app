#ifndef TOUCH_CONTROLS_OVERLAY_H
#define TOUCH_CONTROLS_OVERLAY_H

#import <UIKit/UIKit.h>

/// Touch controls overlay for virtual D-pad and action buttons.
/// Self-installing: automatically attaches to the SDL UIWindow via
/// UIWindowDidBecomeKeyNotification. No engine code changes required.
@interface TouchControlsOverlay : UIView
@end

#endif
