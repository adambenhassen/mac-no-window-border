// pxband: compare two captures inside a column and a row range and print
// "height=<n> rows_with_diff=<n> cols=<x>:<count> …".
//
// It answers one question: does the strip across a window's left edge differ along (almost) the
// whole height? That is the outline — a corner radius only touches the corners, a titlebar rim only
// the top, so a difference running the full height can only be the window's own outline. A count
// per column says which columns moved; the window-edge check uses columns 0-1.
//
// The row range is a fraction of the height (<ylo>..<yhi>): the same strip, away from the corners
// and the titlebar, whatever the display's scale.
//
// Both files must be the same size (they are two captures of one window, by id: nothing is drawn in
// front of a window capture, which is what makes the edge readable). A pixel differs when any of R,
// G, B differs by more than <thr>.
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Reads a PNG into a w*h*4 RGBA8 buffer, top row first.
static uint8_t *readPixels(const char *path, size_t *width, size_t *height) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageSourceRef src = url ? CGImageSourceCreateWithURL(url, NULL) : NULL;
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (!img) {
        fprintf(stderr, "pxband: cannot read %s\n", path);
        goto out;
    }
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    uint8_t *buf = calloc(w * h, 4);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, rgb, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(rgb);
    *width = w;
    *height = h;
    CFRelease(img);
    CFRelease(src);
    CFRelease(url);
    return buf;
out:
    if (img) CFRelease(img);
    if (src) CFRelease(src);
    if (url) CFRelease(url);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 8) {
        fprintf(stderr, "usage: pxband <a.png> <b.png> <thr> <xlo> <xhi> <ylo frac> <yhi frac>\n");
        return 2;
    }
    long thr = strtol(argv[3], NULL, 10);
    long lo = strtol(argv[4], NULL, 10), hi = strtol(argv[5], NULL, 10);
    double ylo = strtod(argv[6], NULL), yhi = strtod(argv[7], NULL);
    if (!(ylo >= 0 && yhi <= 1 && ylo < yhi)) {
        fprintf(stderr, "pxband: row range %g..%g is not inside 0..1\n", ylo, yhi);
        return 2;
    }
    size_t wa = 0, ha = 0, wb = 0, hb = 0;
    uint8_t *a = readPixels(argv[1], &wa, &ha);
    uint8_t *b = a ? readPixels(argv[2], &wb, &hb) : NULL;
    if (!b) { free(a); return 1; }
    if (wa != wb || ha != hb) {
        fprintf(stderr, "pxband: sizes differ (%zux%zu vs %zux%zu)\n", wa, ha, wb, hb);
        free(a); free(b);
        return 1;
    }
    if (lo < 0 || hi > (long)wa || lo >= hi) {
        fprintf(stderr, "pxband: column range %ld..%ld is not inside 0..%zu\n", lo, hi, wa);
        free(a); free(b);
        return 1;
    }
    size_t rowLo = (size_t)floor(ylo * (double)ha), rowHi = (size_t)ceil(yhi * (double)ha);
    if (rowHi > ha) rowHi = ha;
    long *colCounts = calloc(hi - lo, sizeof(long));
    long rowsWithDiff = 0;
    for (size_t y = rowLo; y < rowHi; y++) {
        int any = 0;
        for (long x = lo; x < hi; x++) {
            size_t i = (y * wa + (size_t)x) * 4;
            long d = labs((long)a[i] - (long)b[i]);
            if (labs((long)a[i + 1] - (long)b[i + 1]) > d) d = labs((long)a[i + 1] - (long)b[i + 1]);
            if (labs((long)a[i + 2] - (long)b[i + 2]) > d) d = labs((long)a[i + 2] - (long)b[i + 2]);
            if (d > thr) { colCounts[x - lo]++; any = 1; }
        }
        if (any) rowsWithDiff++;
    }
    printf("height=%zu rows_with_diff=%ld band=%zu..%zu cols=", ha, rowsWithDiff, rowLo, rowHi);
    for (long x = lo; x < hi; x++) printf("%s%ld:%ld", x == lo ? "" : " ", x, colCounts[x - lo]);
    printf("\n");
    free(colCounts);
    free(a);
    free(b);
    return 0;
}
