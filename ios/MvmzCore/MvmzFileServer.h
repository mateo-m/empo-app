#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// Serves the game folder to the web view, and takes the file changes
// that runtime.js sends for the game's fs calls.
// -fvisibility=hidden does not reach Objective-C classes.
__attribute__((visibility("hidden")))
@interface MvmzFileServer : NSObject <WKURLSchemeHandler>

@property(class, nonatomic, readonly) NSString *scheme;

- (instancetype)initWithRoot:(NSString *)root;

@end

NS_ASSUME_NONNULL_END
