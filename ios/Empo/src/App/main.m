// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

// Empo owns UIApplicationMain. The engine is in a core that Empo opens
// with dlopen when the user picks a game, so SDL's main and its app
// delegate do not run.
//
// EmpoAppDelegate (Swift) only sets up the backups, and
// EmpoSceneDelegate (named in Info.plist) builds the UI. SDL does not
// need a delegate: it watches the lifecycle through
// NSNotificationCenter observers that SDL_iPhoneSetEventPump installs
// (SDL_uikitevents.m:45-63).

#import <UIKit/UIKit.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"EmpoAppDelegate");
    }
}
