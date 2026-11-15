#import "AkunCapture.h"

#import <IOSurface/IOSurfaceRef.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach/mach.h>

// IOMobileFramebuffer 是私有框架，不链它，运行时 dlsym，避免编译期依赖。
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
typedef int (*OpenFn)(uint32_t service, uint32_t owningTask, uint32_t type, IOMobileFramebufferRef *out);
typedef int (*GetSurfaceFn)(IOMobileFramebufferRef fb, int layer, IOSurfaceRef *out);
typedef void (*RenderDisplayFn)(uint32_t ctx, CFStringRef display, IOSurfaceRef surface, int x, int y);

static const int kFPS = 30;

@implementation AkunCapture {
    IOMobileFramebufferRef _fb;
    IOSurfaceRef _surface;
    CVPixelBufferRef _pbuf;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    OpenFn _open;
    GetSurfaceFn _getSurface;
    RenderDisplayFn _renderDisplay;
    BOOL _running;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.akun.capture", DISPATCH_QUEUE_SERIAL);
        _open = (OpenFn)dlsym(RTLD_DEFAULT, "IOMobileFramebufferOpen");
        _getSurface = (GetSurfaceFn)dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetLayerDefaultSurface");
        _renderDisplay = (RenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        NSLog(@"[capture] symbols: open=%p surface=%p render=%p", _open, _getSurface, _renderDisplay);
    }
    return self;
}

- (BOOL)openFramebuffer {
    if (_fb) { return YES; }
    if (!_open) { return NO; }
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                       IOServiceMatching("IOMobileFramebuffer"));
    if (!service) {
        NSLog(@"[capture] 找不到 IOMobileFramebuffer 服务");
        return NO;
    }
    int kr = _open(service, mach_task_self(), 0, &_fb);
    IOObjectRelease(service);
    if (kr != 0 || !_fb) {
        NSLog(@"[capture] IOMobileFramebufferOpen 失败 kr=%d", kr);
        return NO;
    }
    return YES;
}

/// 取当前显示层 surface；尺寸变了就重建 pixel buffer。
- (IOSurfaceRef)currentSurface {
    if (_getSurface && [self openFramebuffer]) {
        IOSurfaceRef s = NULL;
        if (_getSurface(_fb, 0, &s) == 0 && s) { return s; }
    }
    if (_renderDisplay) {
        // 兜底：自己开一块 surface，让渲染服务器把主屏画进去。
        if (!_surface) {
            NSDictionary *props = @{
                (id)kIOSurfaceWidth : @(1170),
                (id)kIOSurfaceHeight : @(2532),
                (id)kIOSurfaceBytesPerElement : @(4),
                (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
            };
            _surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        }
        if (_surface) {
            _renderDisplay(0, CFSTR("LCD"), _surface, 0, 0);
            return _surface;
        }
    }
    return NULL;
}

- (void)grabOneFrame {
    IOSurfaceRef surface = [self currentSurface];
    if (!surface) { return; }

    size_t w = IOSurfaceGetWidth(surface);
    size_t h = IOSurfaceGetHeight(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    if (w == 0 || h == 0) { return; }

    if (!_pbuf || CVPixelBufferGetWidth(_pbuf) != w || CVPixelBufferGetHeight(_pbuf) != h) {
        if (_pbuf) { CVPixelBufferRelease(_pbuf); _pbuf = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (id)kCVPixelBufferWidthKey : @(w),
            (id)kCVPixelBufferHeightKey : @(h),
        };
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &_pbuf);
        _width = w;
        _height = h;
        NSLog(@"[capture] surface %zux%zu stride=%zu", w, h, stride);
    }
    if (!_pbuf) { return; }

    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    CVPixelBufferLockBaseAddress(_pbuf, 0);
    void *src = IOSurfaceGetBaseAddress(surface);
    void *dst = CVPixelBufferGetBaseAddress(_pbuf);
    size_t dstStride = CVPixelBufferGetBytesPerRow(_pbuf);
    if (src && dst) {
        size_t copyStride = MIN(stride, dstStride);
        for (size_t y = 0; y < h; y++) {
            memcpy((uint8_t *)dst + y * dstStride, (uint8_t *)src + y * stride, copyStride);
        }
    }
    CVPixelBufferUnlockBaseAddress(_pbuf, 0);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

    if (self.frameHandler) { self.frameHandler(_pbuf); }
}

- (BOOL)start {
    if (_running) { return YES; }
    if (![self currentSurface]) {
        NSLog(@"[capture] 起不来：没有任何可取帧的 surface");
        return NO;
    }
    _running = YES;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              NSEC_PER_SEC / kFPS, NSEC_PER_SEC / kFPS / 2);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf grabOneFrame]; });
    dispatch_resume(_timer);
    NSLog(@"[capture] 已启动 %d fps", kFPS);
    return YES;
}

- (void)stop {
    _running = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    if (_pbuf) { CVPixelBufferRelease(_pbuf); _pbuf = NULL; }
    if (_surface) { CFRelease(_surface); _surface = NULL; }
    if (_fb) { CFRelease(_fb); _fb = NULL; }
}

@end