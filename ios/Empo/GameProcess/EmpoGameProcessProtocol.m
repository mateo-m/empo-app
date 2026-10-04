#import "EmpoGameProcessProtocol.h"

NSXPCInterface *EmpoGameProcessInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(EmpoGameProcess)];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(fetchStatus:)
            argumentIndex:0
                  ofReply:YES];
    [interface setXPCType:XPC_TYPE_DICTIONARY forSelector:@selector(useMemory:) argumentIndex:0 ofReply:NO];
    return interface;
}

NSXPCInterface *EmpoGameProcessHostInterface(void) {
    return [NSXPCInterface interfaceWithProtocol:@protocol(EmpoGameProcessHost)];
}
