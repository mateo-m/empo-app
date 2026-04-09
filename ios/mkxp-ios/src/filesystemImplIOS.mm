//
//  filesystemImplIOS.mm
//  mkxp-ios
//
//  iOS implementation of filesystem functions
//

#import <UIKit/UIKit.h>
#import <SDL_filesystem.h>

#import "filesystemImpl.h"
#import "util/exception.h"

#define PATHTONS(str) [NSFileManager.defaultManager stringWithFileSystemRepresentation:str length:strlen(str)]
#define NSTOPATH(str) [NSFileManager.defaultManager fileSystemRepresentationWithPath:str]

bool filesystemImpl::fileExists(const char *path) {
    @autoreleasepool {
        BOOL isDir;
        return [NSFileManager.defaultManager fileExistsAtPath:PATHTONS(path) isDirectory:&isDir] && !isDir;
    }
}

std::string filesystemImpl::contentsOfFileAsString(const char *path) {
    @autoreleasepool {
        NSString *fileContents = [NSString stringWithContentsOfFile:PATHTONS(path) encoding:NSUTF8StringEncoding error:nil];
        if (fileContents == nil)
            throw Exception(Exception::NoFileError, "Failed to read file at %s", path);
        return std::string(fileContents.UTF8String);
    }
}

bool filesystemImpl::setCurrentDirectory(const char *path) {
    @autoreleasepool {
        return [NSFileManager.defaultManager changeCurrentDirectoryPath:PATHTONS(path)];
    }
}

std::string filesystemImpl::getCurrentDirectory() {
    @autoreleasepool {
        return std::string(NSTOPATH(NSFileManager.defaultManager.currentDirectoryPath));
    }
}

std::string filesystemImpl::normalizePath(const char *path, bool preferred, bool absolute) {
    @autoreleasepool {
        NSString *nspath = [NSURL fileURLWithPath:PATHTONS(path)].URLByStandardizingPath.path;
        NSString *pwd = [NSString stringWithFormat:@"%@/", NSFileManager.defaultManager.currentDirectoryPath];
        if (!absolute) {
            nspath = [nspath stringByReplacingOccurrencesOfString:pwd withString:@""];
        }
        nspath = [nspath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        return std::string(NSTOPATH(nspath));
    }
}

std::string filesystemImpl::getDefaultGameRoot() {
    @autoreleasepool {
        NSString *resourcePath = NSBundle.mainBundle.resourcePath;
        NSFileManager *fm = NSFileManager.defaultManager;
        
        // Check if resourcePath itself is a game root (contains mkxp.json,
        // any .ini file, or any RGSS archive)
        NSArray *topContents = [fm contentsOfDirectoryAtPath:resourcePath error:nil];
        for (NSString *file in topContents) {
            NSString *ext = file.pathExtension.lowercaseString;
            NSString *name = file.lastPathComponent;
            if ([name isEqualToString:@"mkxp.json"] ||
                [ext isEqualToString:@"ini"] ||
                [ext isEqualToString:@"rgssad"] ||
                [ext isEqualToString:@"rgss2a"] ||
                [ext isEqualToString:@"rgss3a"]) {
                return std::string(NSTOPATH(resourcePath));
            }
        }
        
        // Search subdirectories for a folder that looks like a game root
        for (NSString *item in topContents) {
            NSString *subPath = [resourcePath stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:subPath isDirectory:&isDir] && isDir) {
                NSArray *subContents = [fm contentsOfDirectoryAtPath:subPath error:nil];
                for (NSString *file in subContents) {
                    NSString *ext = file.pathExtension.lowercaseString;
                    NSString *name = file.lastPathComponent;
                    if ([name isEqualToString:@"mkxp.json"] ||
                        [ext isEqualToString:@"ini"] ||
                        [ext isEqualToString:@"rgssad"] ||
                        [ext isEqualToString:@"rgss2a"] ||
                        [ext isEqualToString:@"rgss3a"]) {
                        return std::string(NSTOPATH(subPath));
                    }
                }
            }
        }
        
        // Fallback to resource path
        return std::string(NSTOPATH(resourcePath));
    }
}

NSString *getPathForAsset_internal(const char *baseName, const char *ext) {
    NSBundle *assetBundle = [NSBundle bundleWithPath:
                             [NSString stringWithFormat:@"%@/%s",
                              NSBundle.mainBundle.resourcePath, "Assets.bundle"]];
    if (assetBundle == nil)
        return nil;
    return [assetBundle pathForResource:@(baseName) ofType:@(ext)];
}

std::string filesystemImpl::getPathForAsset(const char *baseName, const char *ext) {
    @autoreleasepool {
        NSString *assetPath = getPathForAsset_internal(baseName, ext);
        if (assetPath == nil)
            throw Exception(Exception::NoFileError, "Failed to find the asset named %s.%s", baseName, ext);
        return std::string(NSTOPATH(assetPath));
    }
}

std::string filesystemImpl::contentsOfAssetAsString(const char *baseName, const char *ext) {
    @autoreleasepool {
        NSString *path = getPathForAsset_internal(baseName, ext);
        NSString *fileContents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (fileContents == nil)
            throw Exception(Exception::MKXPError, "Failed to read file at %s", path.UTF8String);
        return std::string(fileContents.UTF8String);
    }
}

std::string filesystemImpl::getResourcePath() {
    @autoreleasepool {
        return std::string(NSTOPATH(NSBundle.mainBundle.resourcePath));
    }
}

std::string filesystemImpl::selectPath(SDL_Window *win, const char *msg, const char *prompt) {
    // No file picker on iOS for now — return empty
    (void)win; (void)msg; (void)prompt;
    return std::string();
}
