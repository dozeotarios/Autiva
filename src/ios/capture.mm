// Screen capture for iOS 16 palera1n, inside backboardd.
//
// Why this lives in backboardd at all: CARenderServerRenderDisplay silently
// no-ops outside backboardd's process context on iOS 16, which is why the
// standalone screenshot binary produced all-black PNGs.
//
// Changes vs v8 (all three are stability, not features):
//   1. Metal objects are created ONCE. v8 built a fresh MTLDevice, CIContext
//      and command queue on every capture — on a device with ~14 MB of free
//      pages that is the memory churn that ends in a jetsam kill of backboardd.
//   2. The fallback IOSurface is pooled instead of allocated per capture.
//   3. The framebuffer reference from IOMobileFramebufferGetMainDisplay is
//      released; v8 leaked it on every screenshot.
// Capture runs on the caller's thread (the command queue), never the main
// queue, so a 250 ms PNG encode cannot stall input delivery.
#include <CoreGraphics/CoreGraphics.h>
#include <CoreImage/CoreImage.h>
#include <Foundation/Foundation.h>
#include <ImageIO/ImageIO.h>
#include <Metal/Metal.h>
#import <UIKit/UIKit.h>
#include <MobileCoreServices/MobileCoreServices.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>

#include "ios.hpp"

namespace autiva {
namespace {

extern "C" {
extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfaceBytesPerRow;
extern const CFStringRef kIOSurfacePixelFormat;

IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
kern_return_t IOSurfaceLock(IOSurfaceRef surface, uint32_t options, uint32_t* seed);
kern_return_t IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options, uint32_t* seed);
void* IOSurfaceGetBaseAddress(IOSurfaceRef surface);
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);
size_t IOSurfaceGetWidth(IOSurfaceRef surface);
size_t IOSurfaceGetHeight(IOSurfaceRef surface);
size_t IOSurfaceGetBytesPerElement(IOSurfaceRef surface);
size_t IOSurfaceGetAllocSize(IOSurfaceRef surface);
OSType IOSurfaceGetPixelFormat(IOSurfaceRef surface);
}

extern "C" {
int CARenderServerRenderDisplay(mach_port_t server_port, CFStringRef display_name,
                                IOSurfaceRef surface, int x, int y);
mach_port_t CARenderServerGetServerPort(const char* service_name);
mach_port_t CARenderServerGetPort(void);
}

constexpr uint32_t kLockReadOnly = 0x00000001;
constexpr uint32_t kFormatBGRA = 0x42475241;  // 'BGRA'
constexpr int kCaptureRetries = 4;

// ── cached Metal stack ──────────────────────────────────────────────────────
struct MetalCache {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    CIContext* context;
};

MetalCache& metal() {
    static MetalCache cache{};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache.device = MTLCreateSystemDefaultDevice();
        if (cache.device) {
            cache.queue = [cache.device newCommandQueue];
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            cache.context = [CIContext contextWithMTLDevice:cache.device
                                                   options:@{
                                                       kCIContextOutputColorSpace : (__bridge id)cs,
                                                       kCIContextWorkingColorSpace : (__bridge id)cs,
                                                   }];
            CGColorSpaceRelease(cs);
        }
    });
    return cache;
}

IOSurfaceRef pooled_surface(size_t w, size_t h) {
    static IOSurfaceRef surface = nullptr;
    static size_t sw = 0, sh = 0;
    if (surface && sw == w && sh == h) return surface;
    if (surface) {
        CFRelease(surface);
        surface = nullptr;
    }
    NSDictionary* props = @{
        (__bridge NSString*)kIOSurfaceWidth : @((int)w),
        (__bridge NSString*)kIOSurfaceHeight : @((int)h),
        (__bridge NSString*)kIOSurfaceBytesPerElement : @(4),
        (__bridge NSString*)kIOSurfaceBytesPerRow : @((int)(w * 4)),
        (__bridge NSString*)kIOSurfacePixelFormat : @(kFormatBGRA),
    };
    surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    sw = surface ? w : 0;
    sh = surface ? h : 0;
    return surface;
}

// ── IOMobileFramebuffer: the live front buffer ───────────────────────────────
typedef CFTypeRef IOMobileFramebufferRef;
typedef kern_return_t (*GetMainDisplayFn)(IOMobileFramebufferRef*);
typedef kern_return_t (*CopyLayerSurfaceFn)(IOMobileFramebufferRef, int, IOSurfaceRef*);

struct Iomfb {
    GetMainDisplayFn get_main = nullptr;
    CopyLayerSurfaceFn copy_layer = nullptr;
    bool loaded = false;
};

Iomfb& iomfb() {
    static Iomfb f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void* h = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/"
                         "IOMobileFramebuffer",
                         RTLD_LAZY);
        if (!h) return;
        f.get_main = (GetMainDisplayFn)dlsym(h, "IOMobileFramebufferGetMainDisplay");
        f.copy_layer =
            (CopyLayerSurfaceFn)dlsym(h, "IOMobileFramebufferCopyLayerDisplayedSurface");
        f.loaded = f.get_main && f.copy_layer;
    });
    return f;
}

CGImageRef cg_image_from_surface(IOSurfaceRef surface) {
    const size_t w = IOSurfaceGetWidth(surface);
    const size_t h = IOSurfaceGetHeight(surface);
    const OSType fmt = IOSurfaceGetPixelFormat(surface);

    MTLPixelFormat mtl_fmt = MTLPixelFormatBGRA8Unorm_sRGB;
    if (fmt == 0x62336138 /* 'b3a8' BGRA10_XR sRGB */) {
        mtl_fmt = MTLPixelFormatBGR10_XR_sRGB;
    } else if (fmt != kFormatBGRA) {
        log_line("capture: unknown surface format, guessing BGRA8");
    }

    MetalCache& m = metal();
    if (!m.device || !m.context) return nullptr;

    MTLTextureDescriptor* desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:mtl_fmt
                                     width:w
                                    height:h
                                 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [m.device newTextureWithDescriptor:desc iosurface:surface plane:0];
    if (!tex) return nullptr;

    CIImage* image = [CIImage imageWithMTLTexture:tex options:nil];
    if (!image) return nullptr;
    image = [image imageByApplyingOrientation:4];  // surfaces arrive Y-flipped

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef out = [m.context createCGImage:image
                                     fromRect:CGRectMake(0, 0, w, h)
                                       format:kCIFormatBGRA8
                                   colorSpace:cs];
    CGColorSpaceRelease(cs);
    return out;  // caller releases
}

bool surface_has_pixels(IOSurfaceRef surface) {
    if (IOSurfaceLock(surface, kLockReadOnly, nullptr) != 0) return false;
    const size_t bpr = IOSurfaceGetBytesPerRow(surface);
    const size_t h = IOSurfaceGetHeight(surface);
    const uint8_t* base = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(surface));
    bool has = false;
    if (base) {
        for (size_t r = 0; r < 16 && !has; ++r) {
            const uint8_t* row = base + (h * r) / 16 * bpr;
            for (size_t c = 0; c < bpr && c < 4096; c += 256) {
                if (row[c]) {
                    has = true;
                    break;
                }
            }
        }
    }
    IOSurfaceUnlock(surface, kLockReadOnly, nullptr);
    return has;
}

CGImageRef capture_full_size() {
    Iomfb& f = iomfb();
    if (f.loaded) {
        IOMobileFramebufferRef fb = nullptr;
        if (f.get_main(&fb) == 0 && fb) {
            for (int layer = 0; layer < 4; ++layer) {
                IOSurfaceRef surface = nullptr;
                if (f.copy_layer(fb, layer, &surface) == 0 && surface) {
                    CGImageRef image = cg_image_from_surface(surface);
                    CFRelease(surface);
                    CFRelease(fb);
                    if (image) return image;
                    log_line("capture: iomfb decode failed, falling back to CARenderServer");
                    break;  // fall through to the render-server path
                }
            }
            // v8 leaked this reference on every capture.
            CFRelease(fb);
        }
    }

    IOSurfaceRef surface = pooled_surface(kScreenW, kScreenH);
    if (!surface) return nullptr;

    mach_port_t port_a = CARenderServerGetServerPort(nullptr);
    mach_port_t port_b = CARenderServerGetPort();
    mach_port_t ports[] = {0, port_a, port_b};
    bool rendered = false;
    for (mach_port_t port : ports) {
        if (CARenderServerRenderDisplay(port, nullptr, surface, 0, 0) == 0 &&
            surface_has_pixels(surface)) {
            rendered = true;
            break;
        }
    }
    if (!rendered) return nullptr;
    return cg_image_from_surface(surface);
}

// Down-scale for callers that only need OCR-grade pixels (half resolution is
// plenty) without paying full-size PNG cost.
CGImageRef scaled_copy(CGImageRef src, double scale) {
    if (scale >= 0.999 || scale <= 0.0) return CGImageRetain(src);
    const size_t w = CGImageGetWidth(src);
    const size_t h = CGImageGetHeight(src);
    const size_t nw = static_cast<size_t>(w * scale);
    const size_t nh = static_cast<size_t>(h * scale);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, nw, nh, 8, nw * 4, cs,
                                             kCGImageAlphaPremultipliedFirst |
                                                 kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return CGImageRetain(src);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, nw, nh), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out ? out : CGImageRetain(src);
}

bool write_png(CGImageRef image, const std::string& path) {
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, kUTTypePNG, 1, nullptr);
    if (!dest) return false;
    CGImageDestinationAddImage(dest, image, nullptr);
    const bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok;
}

}  // namespace

bool capture_png_n(const std::string& out_path, double scale, int retries,
                   std::string& err) {
    if (out_path.empty()) {
        err = std::string(kErrMissingField);
        return false;
    }
    const uint64_t started = mono_ms();

    // A napped display makes the capture path fail in ~1 ms. The retry used to
    // live in the host client, which meant every new caller (plan steps,
    // recorder) had to re-implement it — and a failed capture mid-plan would
    // abort a whole session. Own it here: nudge the display, wait, retry.
    CGImageRef full = nullptr;
    for (int attempt = 0; attempt <= retries && !full; ++attempt) {
        if (attempt > 0) {
            const int fd = open(kWakeTriggerPath, O_WRONLY | O_CREAT, 0644);
            if (fd >= 0) close(fd);
            log_line("capture: napped (attempt " + std::to_string(attempt) + "), woke display");
            sleep_ms(850);
        }
        full = capture_full_size();
    }
    if (!full) {
        err = "capture_failed";
        log_line("capture: failed after " + std::to_string(mono_ms() - started) + "ms");
        return false;
    }
    CGImageRef out = scaled_copy(full, scale);
    const bool ok = write_png(out, out_path);
    if (out) CGImageRelease(out);
    CGImageRelease(full);
    if (!ok) {
        err = "write_failed";
        return false;
    }
    log_line("capture: " + std::to_string(mono_ms() - started) + "ms -> " + out_path +
             " scale=" + std::to_string(scale));
    return true;
}

bool capture_png(const std::string& out_path, double scale, std::string& err) {
    return capture_png_n(out_path, scale, kCaptureRetries, err);
}

bool clipboard_set(const std::string& text, std::string& err) {
    @autoreleasepool {
        NSString* s = [NSString stringWithUTF8String:text.c_str()];
        if (!s) {
            err = std::string(kErrBadField);
            return false;
        }
        UIPasteboard* pb = [UIPasteboard generalPasteboard];
        if (!pb) {
            err = std::string(kErrInternal);
            return false;
        }
        // v8 accepted a `timeout` field here; the write itself is synchronous,
        // so it is accepted and ignored rather than invented around.
        pb.string = s;
        log_line("clipboard: set " + std::to_string(text.size()) + " bytes");
    }
    return true;
}

bool clipboard_get(std::string& out, std::string& err) {
    @autoreleasepool {
        UIPasteboard* pb = [UIPasteboard generalPasteboard];
        if (!pb) {
            err = std::string(kErrInternal);
            return false;
        }
        NSString* s = pb.string;
        if (!s) {
            out.clear();
            return true;
        }
        out = s.UTF8String ? s.UTF8String : "";
    }
    return true;
}

}  // namespace autiva
