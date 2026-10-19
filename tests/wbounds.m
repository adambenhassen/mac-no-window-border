// wbounds: print "<wid> <x> <y> <w> <h>" for one window id, in CoreGraphics coordinates
// (origin at the top-left of the main display). tests/e2e.sh uses it to put a screencapture -R
// strip across a window's left edge; tests/winpixels reads the window itself by id, which needs no
// position, so this is only for region captures.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <stdio.h>
#import <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: wbounds <wid>\n");
        return 2;
    }
    unsigned int want = (unsigned int)atoi(argv[1]);
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef window = CFArrayGetValueAtIndex(list, i);
        CFNumberRef number = CFDictionaryGetValue(window, kCGWindowNumber);
        unsigned int wid = 0;
        if (!number || !CFNumberGetValue(number, kCFNumberIntType, &wid) || wid != want) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(window, kCGWindowBounds), &bounds)) {
            fprintf(stderr, "wbounds: %u has no bounds\n", want);
            return 1;
        }
        printf("%u %.0f %.0f %.0f %.0f\n", want, bounds.origin.x, bounds.origin.y,
               bounds.size.width, bounds.size.height);
        return 0;
    }
    fprintf(stderr, "wbounds: no window %u\n", want);
    return 1;
}
