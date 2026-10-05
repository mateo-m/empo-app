#import <xpc/xpc.h>

// Puts the memory of this process in the block that the app lent it
// (EmpoGameProcessMemory* keys). Call it before the core opens.
void EmpoUseAppMemory(xpc_object_t memory);
