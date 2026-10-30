// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#import "EmpoGameProcessProtocol.h"

NSXPCInterface *EmpoGameProcessInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(EmpoGameProcess)];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(fetchStatus:)
            argumentIndex:0
                  ofReply:YES];
    [interface setXPCType:XPC_TYPE_DICTIONARY forSelector:@selector(useMemory:reply:) argumentIndex:0 ofReply:NO];
    return interface;
}
