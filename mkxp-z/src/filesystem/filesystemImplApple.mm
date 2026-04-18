//
//  filesystemImplApple.mm
//  Player
//
//  Created by ゾロアーク on 11/21/20.
//

#import <AppKit/AppKit.h>
#import <SDL_syswm.h>

#import <SDL_filesystem.h>

#import "filesystemImpl.h"
#import "util/exception.h"

#define PATHTONS(str) [NSFileManager.defaultManager stringWithFileSystemRepresentation:str length:strlen(str)]

#define NSTOPATH(str) [NSFileManager.defaultManager fileSystemRepresentationWithPath:str]

bool filesystemImpl::fileExists(const char *path) {
    @autoreleasepool{
        BOOL isDir;
        return  [NSFileManager.defaultManager fileExistsAtPath:PATHTONS(path) isDirectory: &isDir] && !isDir;
    }
}



std::string filesystemImpl::contentsOfFileAsString(const char *path) {
    @autoreleasepool {
        NSString *fileContents = [NSString stringWithContentsOfFile: PATHTONS(path)];
        if (fileContents == nil)
            throw Exception(Exception::NoFileError, "Failed to read file at %s", path);
        
        return std::string(fileContents.UTF8String);
    }
}


bool filesystemImpl::setCurrentDirectory(const char *path) {
    @autoreleasepool {
        return [NSFileManager.defaultManager changeCurrentDirectoryPath: PATHTONS(path)];
    }
}

std::string filesystemImpl::getCurrentDirectory() {
    @autoreleasepool {
        return std::string(NSTOPATH(NSFileManager.defaultManager.currentDirectoryPath));
    }
}

std::string filesystemImpl::normalizePath(const char *path, bool preferred, bool absolute) {
    @autoreleasepool {
        // When caller wants a relative path and the input is already
        // relative, skip the NSURL roundtrip entirely. Feeding a
        // relative string like "Data/Scripts.rxdata" to
        // `NSURL fileURLWithPath:` resolves it against "/" to produce
        // "/Data/Scripts.rxdata", and the pwd-strip below then
        // fails to find the cwd prefix (because there is none), so
        // we were returning a bogus leading-slash path that PhysFS
        // couldn't look up. Keep relative paths relative.
        NSString *input = PATHTONS(path);
        if (!absolute && ![input hasPrefix:@"/"]) {
            NSString *normalized = [input stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            return std::string(NSTOPATH(normalized));
        }

        NSString *nspath = [NSURL fileURLWithPath:input].URLByStandardizingPath.path;
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
        NSString *p = [NSString stringWithFormat: @"%@/%s", NSBundle.mainBundle.bundlePath, "Contents/Game"];
        return std::string(NSTOPATH(p));
    }
}

NSString *getPathForAsset_internal(const char *baseName, const char *ext) {
    NSBundle *assetBundle = [NSBundle bundleWithPath:
                             [NSString stringWithFormat:
                              @"%@/%s",
                              NSBundle.mainBundle.resourcePath,
                              "Assets.bundle"
                             ]
                            ];
    
    if (assetBundle == nil)
        return nil;
    
    return [assetBundle pathForResource: @(baseName) ofType: @(ext)];
}

std::string filesystemImpl::getPathForAsset(const char *baseName, const char *ext) {
    @autoreleasepool {
        NSString *assetPath = getPathForAsset_internal(baseName, ext);
        if (assetPath == nil)
            throw Exception(Exception::NoFileError, "Failed to find the asset named %s.%s", baseName, ext);
        
        return std::string(NSTOPATH(getPathForAsset_internal(baseName, ext)));
    }
}

std::string filesystemImpl::contentsOfAssetAsString(const char *baseName, const char *ext) {
    @autoreleasepool {
        NSString *path = getPathForAsset_internal(baseName, ext);
        NSString *fileContents = [NSString stringWithContentsOfFile: path];
        
        // This should never fail
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
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseDirectories = true;
        panel.canChooseFiles = false;
        
        if (msg) panel.message = @(msg);
        if (prompt) panel.prompt = @(prompt);
        //panel.directoryURL = [NSURL fileURLWithPath:NSFileManager.defaultManager.currentDirectoryPath];
        
        SDL_SysWMinfo windowinfo{};
        SDL_GetWindowWMInfo(win, &windowinfo);
        
        [panel beginSheetModalForWindow:windowinfo.info.cocoa.window completionHandler:^(NSModalResponse res){
            [NSApp stopModalWithCode:res];
        }];
        
        [NSApp runModalForWindow:windowinfo.info.cocoa.window];
        
        // The window needs to be brought to the front again after the OpenPanel closes
        [windowinfo.info.cocoa.window makeKeyAndOrderFront:nil];
        if (panel.URLs.count > 0)
            return std::string(NSTOPATH(panel.URLs[0].path));
        
        return std::string();
    }
}
