// Empo-Bridging-Header.h
// Exposes C bridge functions and ObjC touch control classes to Swift

#import "GameCore.h"
#import "EmpoAppCore.h"
#import "GameProcessClient.h"
#import "TouchControls.h"

// libarchive - for zip/7z/rar extraction in ArchiveExtractor.
#import <archive.h>
#import <archive_entry.h>

// libmspack (vendored) - CAB reader for self-extracting .exe game
// installers in ArchiveExtractor. libarchive's CAB/LZX path is
// broken on real-world RPG Maker installers. See
// vendor/libmspack/README.md.
#import <mspack.h>

// Security.framework exports these on iOS, but the iOS SDK has no
// header for them. DataDirectory reads the app group names from the
// app's own signature with them.
typedef struct CF_BRIDGED_TYPE(id) __SecTask *SecTaskRef;
SecTaskRef _Nullable SecTaskCreateFromSelf(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;
CFTypeRef _Nullable SecTaskCopyValueForEntitlement(SecTaskRef _Nonnull task, CFStringRef _Nonnull entitlement,
                                                   CFErrorRef _Nullable *_Nullable error) CF_RETURNS_RETAINED;
