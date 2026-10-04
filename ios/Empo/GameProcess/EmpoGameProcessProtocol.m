#import "EmpoGameProcessProtocol.h"

NSXPCInterface *EmpoGameProcessInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(EmpoGameProcess)];
    [interface setClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
              forSelector:@selector(fetchStatus:)
            argumentIndex:0
                  ofReply:YES];
    return interface;
}
