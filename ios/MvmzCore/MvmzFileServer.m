#import "MvmzFileServer.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation MvmzFileServer {
    NSString *_root;
    dispatch_queue_t _queue;
    // Tasks that WebKit stopped. WebKit throws if a stopped task gets
    // an answer.
    NSHashTable<id<WKURLSchemeTask>> *_stopped;
}

static NSString *_Nullable realPath(NSString *path) {
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) ? @(resolved) : nil;
}

+ (NSString *)scheme {
    return @"mvmz";
}

- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super init])) {
        _root = realPath(root) ?: root.stringByStandardizingPath;
        _queue = dispatch_queue_create("mvmz.files", DISPATCH_QUEUE_SERIAL);
        _stopped = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

// The file that a URL names, or nil when it is outside the game folder.
//
// Games made on Windows often name a file with other capitals than the
// file on disk has, and the file system of an iPhone tells them apart.
// So a part of the path that is not there is looked up again without
// case.
//
// A game can hold a symbolic link, so each part that is there must
// resolve to a path in the game folder.
- (nullable NSString *)pathForURL:(NSURL *)url {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *path = _root;
    for (NSString *part in url.path.pathComponents) {
        if ([part isEqualToString:@"/"] || part.length == 0) {
            continue;
        }
        if ([part isEqualToString:@".."] || [part isEqualToString:@"."]) {
            return nil;
        }
        NSString *next = [path stringByAppendingPathComponent:part];
        if (![files fileExistsAtPath:next]) {
            for (NSString *name in [files contentsOfDirectoryAtPath:path error:nil]) {
                if ([name caseInsensitiveCompare:part] == NSOrderedSame) {
                    next = [path stringByAppendingPathComponent:name];
                    break;
                }
            }
        }
        if ([files fileExistsAtPath:next]) {
            NSString *real = realPath(next);
            if (!real ||
                !([real isEqualToString:_root] || [real hasPrefix:[_root stringByAppendingString:@"/"]])) {
                return nil;
            }
        }
        path = next;
    }
    return path;
}

static NSString *mimeType(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"js"]) return @"text/javascript";
    if ([ext isEqualToString:@"wasm"]) return @"application/wasm";
    if ([ext isEqualToString:@"json"]) return @"application/json";
    return [UTType typeWithFilenameExtension:ext].preferredMIMEType ?: @"application/octet-stream";
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURLRequest *request = task.request;
    NSString *path = [self pathForURL:request.URL];
    NSString *destination = [request valueForHTTPHeaderField:@"Destination"];
    NSString *destinationPath = destination ? [self pathForURL:[NSURL URLWithString:destination]] : nil;
    dispatch_async(_queue, ^{
        NSInteger status = 200;
        NSData *body = nil;
        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        if (!path || (destination && !destinationPath)) {
            status = 403;
        } else {
            status = [self answer:request path:path destination:destinationPath headers:headers body:&body];
        }
        if (!headers[@"Content-Length"]) {
            headers[@"Content-Length"] = @(body.length).stringValue;
        }
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                  statusCode:status
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:headers];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self->_stopped containsObject:task]) {
                return;
            }
            [task didReceiveResponse:response];
            if (body.length) {
                [task didReceiveData:body];
            }
            [task didFinish];
        });
    });
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    [_stopped addObject:task];
}

// Runs one request on the file queue and returns the HTTP status.
- (NSInteger)answer:(NSURLRequest *)request
               path:(NSString *)path
        destination:(nullable NSString *)destination
            headers:(NSMutableDictionary<NSString *, NSString *> *)headers
               body:(NSData **)body {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *method = request.HTTPMethod;
    BOOL directory = NO;
    const BOOL exists = [files fileExistsAtPath:path isDirectory:&directory];
    NSError *error = nil;

    // "/" is the game folder. Only read it, or a game can delete itself.
    const BOOL reads = [method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"];
    if (!reads && ([path isEqualToString:_root] || [destination isEqualToString:_root])) {
        return 403;
    }

    if ([method isEqualToString:@"PUT"]) {
        [files createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        return [request.HTTPBody ?: [NSData data] writeToFile:path options:NSDataWritingAtomic error:&error]
                   ? 204
                   : [self failure:error body:body];
    }
    if ([method isEqualToString:@"MKCOL"]) {
        return [files createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]
                   ? 204
                   : [self failure:error body:body];
    }
    if (!exists) {
        return 404;
    }
    if ([method isEqualToString:@"DELETE"]) {
        return [files removeItemAtPath:path error:&error] ? 204 : [self failure:error body:body];
    }
    if ([method isEqualToString:@"MOVE"]) {
        // Node's rename replaces the file at the destination.
        [files removeItemAtPath:destination error:nil];
        return [files moveItemAtPath:path toPath:destination error:&error] ? 204 : [self failure:error body:body];
    }

    NSDictionary<NSFileAttributeKey, id> *attributes = [files attributesOfItemAtPath:path error:nil];
    headers[@"X-Mvmz-Kind"] = directory ? @"directory" : @"file";
    headers[@"X-Mvmz-Mtime"] =
        @((long long)([attributes.fileModificationDate timeIntervalSince1970] * 1000)).stringValue;

    if (directory) {
        NSArray *names = [files contentsOfDirectoryAtPath:path error:nil] ?: @[];
        NSData *json = [NSJSONSerialization dataWithJSONObject:names options:0 error:nil];
        headers[@"Content-Type"] = @"application/json";
        if ([method isEqualToString:@"HEAD"]) {
            headers[@"Content-Length"] = @"0";
        } else {
            *body = json;
        }
        return 200;
    }

    const unsigned long long size = attributes.fileSize;
    headers[@"Content-Type"] = mimeType(path);
    headers[@"Accept-Ranges"] = @"bytes";
    if ([method isEqualToString:@"HEAD"]) {
        headers[@"Content-Length"] = @(size).stringValue;
        return 200;
    }

    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
    if (!data) {
        return [self failure:error body:body];
    }

    // Video and long audio come in parts: "bytes=START-" or
    // "bytes=START-END", with END included.
    NSString *range = [request valueForHTTPHeaderField:@"Range"];
    if ([range hasPrefix:@"bytes="] && data.length > 0) {
        NSArray<NSString *> *ends = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
        const unsigned long long start = ends[0].longLongValue;
        unsigned long long end = ends.count > 1 && ends[1].length ? ends[1].longLongValue : data.length - 1;
        end = MIN(end, data.length - 1);
        if (ends[0].length == 0 || start > end) {
            headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%lu", (unsigned long)data.length];
            return 416;
        }
        headers[@"Content-Range"] =
            [NSString stringWithFormat:@"bytes %llu-%llu/%lu", start, end, (unsigned long)data.length];
        *body = [data subdataWithRange:NSMakeRange(start, end - start + 1)];
        return 206;
    }
    *body = data;
    return 200;
}

- (NSInteger)failure:(NSError *)error body:(NSData **)body {
    *body = [error.localizedDescription dataUsingEncoding:NSUTF8StringEncoding];
    return 500;
}

@end
