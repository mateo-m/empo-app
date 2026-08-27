// Empo-Bridging-Header.h
// Exposes C bridge functions and ObjC touch control classes to Swift

#import "app_bridge.h"
#import "TouchControls.h"

// The SDL app delegate, so `EmpoAppDelegate` can subclass it.
#import "EmpoAppDelegate.h"

// libarchive - for zip/7z/rar extraction in ArchiveExtractor.
#import <archive.h>
#import <archive_entry.h>

// libmspack (vendored) - CAB reader for self-extracting .exe game
// installers in ArchiveExtractor. libarchive's CAB/LZX path is
// broken on real-world RPG Maker installers. See
// vendor/libmspack/README.md.
#import <mspack.h>
