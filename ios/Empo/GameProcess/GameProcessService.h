// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#import <Foundation/Foundation.h>

#import "EmpoGameProcessProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// The generated GameCoreRelayService.m implements it.
@interface EmpoGameCoreRelayService : NSObject <EmpoGameCoreRelay>
@end

@interface EmpoGameProcessService : EmpoGameCoreRelayService <EmpoGameProcess>
@end

// Runs a gamecore_* call on the main thread, after the calls that came
// before it. It drops the call when no core is open.
void EmpoGameProcessOnMain(dispatch_block_t call);

// Serves the app's connection to this game process. Returns NO when a
// connection came already: a game process serves one game.
BOOL EmpoGameProcessAccept(NSXPCConnection *connection);

// Empo.app/Frameworks, which holds the cores.
NSURL *EmpoAppFrameworksURL(void);

// The scene of this process has its size. Runs on the main thread.
void EmpoGameProcessSceneHasSize(void);

NS_ASSUME_NONNULL_END
