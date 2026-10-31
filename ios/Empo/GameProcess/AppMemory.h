// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

// Puts the memory of this process in the block that the app lent it
// (EmpoGameProcessMemory* keys). Call it before the core opens. Returns
// nil, or why the process keeps its own memory.
NSString *_Nullable EmpoUseAppMemory(xpc_object_t memory);
