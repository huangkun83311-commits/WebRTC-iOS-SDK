//  AkunCapture — 屏幕抓取
//
//  为什么不用 IOMobileFramebufferOpen：
//    真机（iOS 16.7.16）上 IOMobileFramebufferOpen 返回 kr=0xE00002E2（无权限），
//    守护进程拿不到 framebuffer 层。AKUN 的做法完全绕开它：
//      自建一块 IOSurface → CARenderServerRenderDisplay(0, "LCD", surface, 0, 0)
//      渲染服务器直接把主屏画进这块 surface，不需要 framebuffer 权限。
//
//  顺带解决了 CPU 问题：用 CVPixelBufferCreateWithIOSurface 把 surface 直接包成
//  CVPixelBuffer，零拷贝交给 WebRTC，不再每帧 memcpy 11.8MB。
//
//  双缓冲：渲染到 A 的同时推 B，避免 WebRTC 还在编码时被下一帧覆盖（撕裂）。

#import "AkunCapture.h"

#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#import "vendor/UIScreen+Private.h"

typedef void (*RenderDisplayFn)(uint32_t ctx, CFStringRef display, IOSurfaceRef surface, int x, int y);
typedef CFIndex (*GetDirtyFrameCountFn)(void *);

static const int kDefaultFPS = 12;
static const uint32_t kPixelFormatBGRA = 0x42475241;   // 'BGRA'

@implementation AkunCapture {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    RenderDisplayFn _renderDisplay;
    GetDirtyFrameCountFn _dirtyFrameCount;
    CFIndex _lastDirtyCount;
    NSTimeInterval _lastPushTime;
    IOSurfaceRef _surfaces[2];
    CVPixelBufferRef _pixelBuffers[2];
    int _cur;
    BOOL _running;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.akun.capture", DISPATCH_QUEUE_SERIAL);
        _fps = kDefaultFPS;
        _renderDisplay = (RenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        _dirtyFrameCount = (GetDirtyFrameCountFn)dlsym(RTLD_DEFAULT, "CARenderServerGetDirtyFrameCount");
        NSLog(@"[capture] symbols: render=%p dirtyCount=%p", _renderDisplay, _dirtyFrameCount);
    }
    return self;
}

#pragma mark - 屏幕尺寸

/// 抓取尺寸：**必须**用渲染服务器实际出图的那块尺寸（_unjailedReferenceBoundsInPixels）。
/// 用 nativeBounds（1080x1920）会小一圈，渲染结果被裁掉右侧/底部（图标列被切、坐标也整体偏）。
- (CGSize)screenPixelSize {
    @try {
        UIScreen *screen = [UIScreen mainScreen];
        CGRect r = [screen _unjailedReferenceBoundsInPixels];
        if (r.size.width > 0 && r.size.height > 0) { return r.size; }
    } @catch (NSException *e) {
        NSLog(@"[capture] _unjailedReferenceBoundsInPixels 异常: %@", e.reason);
    }
    @try {
        UIScreen *screen = [UIScreen mainScreen];
        CGSize s = screen.nativeBounds.size;
        if (s.width > 0 && s.height > 0) { return s; }
    } @catch (NSException *e) {
        NSLog(@"[capture] UIScreen 取尺寸异常: %@", e.reason);
    }
    return CGSizeMake(1170, 2532);
}

#pragma mark - 建 surface

- (BOOL)buildSurfacesIfNeeded {
    if (_surfaces[0]) { return YES; }

    CGSize sz = [self screenPixelSize];
    _screenWidth = (NSInteger)lround(sz.width);
    _screenHeight = (NSInteger)lround(sz.height);
    NSLog(@"[capture] 屏像素 %ld x %ld", (long)_screenWidth, (long)_screenHeight);
    if (_screenWidth == 0 || _screenHeight == 0) { return NO; }

    // 出图尺寸 = 屏像素 × scale：让渲染服务器直接按目标尺寸出图（GPU 缩放，零 CPU），
    // 编码器输入就是 434x772 这种小图，不必再由 libwebrtc 逐帧缩放（那是延迟的大头）。
    double s = (_outputScale > 0.05 && _outputScale <= 1.0) ? _outputScale : 1.0;
    size_t w = (size_t)lround((double)_screenWidth * s);
    size_t h = (size_t)lround((double)_screenHeight * s);
    w &= ~1UL; h &= ~1UL;                     // 宽高取偶数
    if (w < 16) { w = 16; }
    if (h < 16) { h = 16; }
    NSLog(@"[capture] 出图 %zux%zu（scale=%.2f）", w, h, s);

    size_t bytesPerRow = ((w * 4) + 63) & ~63UL;   // 64 字节对齐

    NSDictionary *props = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(4),
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(bytesPerRow),
        (__bridge NSString *)kIOSurfaceWidth : @(w),
        (__bridge NSString *)kIOSurfaceHeight : @(h),
        (__bridge NSString *)kIOSurfacePixelFormat : @(kPixelFormatBGRA),
        (__bridge NSString *)kIOSurfaceAllocSize : @(bytesPerRow * h),
    };

    NSDictionary *cvAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };

    for (int i = 0; i < 2; i++) {
        // 首选 CoreVideo 自己建（它内部按系统要求填属性，比手搓 IOSurfaceCreate 成功率高），
        // 失败再退回裸 IOSurfaceCreate。
        CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)cvAttrs,
                                          &_pixelBuffers[i]);
        if (cr == kCVReturnSuccess && _pixelBuffers[i]) {
            _surfaces[i] = CVPixelBufferGetIOSurface(_pixelBuffers[i]);
            if (_surfaces[i]) { CFRetain(_surfaces[i]); }
        }
        if (!_surfaces[i]) {
            if (_pixelBuffers[i]) { CVPixelBufferRelease(_pixelBuffers[i]); _pixelBuffers[i] = NULL; }
            _surfaces[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
            if (_surfaces[i]) {
                CVReturn cr2 = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, _surfaces[i],
                                                                (__bridge CFDictionaryRef)cvAttrs,
                                                                &_pixelBuffers[i]);
                if (cr2 != kCVReturnSuccess) {
                    NSLog(@"[capture] CVPixelBufferCreateWithIOSurface 失败 slot=%d cr=%d", i, (int)cr2);
                    return NO;
                }
            }
        }
        if (!_surfaces[i] || !_pixelBuffers[i]) {
            NSLog(@"[capture] slot=%d 两条路都没建出 surface（cv=%d）", i, (int)cr);
            return NO;
        }
    }

    _width = w;
    _height = h;
    NSLog(@"[capture] surface %zux%zu stride=%zu（零拷贝，双缓冲）", w, h, bytesPerRow);
    return YES;
}

/// scale 变了要重建 surface（出图尺寸跟着变），否则画面会一直停在旧尺寸
- (void)setOutputScale:(double)scale {
    double s = (scale > 0.05 && scale <= 1.0) ? scale : 1.0;
    if (fabs(s - _outputScale) < 0.001) { return; }
    @synchronized (self) {
        _outputScale = s;
        // 释放旧的两块，下一帧 grabOneFrame 会按新尺寸重建
        for (int i = 0; i < 2; i++) {
            if (_pixelBuffers[i]) { CVPixelBufferRelease(_pixelBuffers[i]); _pixelBuffers[i] = NULL; }
            if (_surfaces[i]) { CFRelease(_surfaces[i]); _surfaces[i] = NULL; }
        }
        _width = 0; _height = 0;
        NSLog(@"[capture] 输出缩放到 %.2f，重建 surface", s);
    }
}

#pragma mark - 抓帧

- (void)grabOneFrame {
    if (![self buildSurfacesIfNeeded]) { return; }
    if (!_renderDisplay) {
        static BOOL warned = NO;
        if (!warned) { NSLog(@"[capture] 找不到 CARenderServerRenderDisplay"); warned = YES; }
        return;
    }

    // 画面没变就不推（AKUN 用 dirtyFrameCount 做同样的判断），但每秒至少补一帧保活
    if (_dirtyFrameCount) {
        CFIndex c = _dirtyFrameCount(NULL);
        if (c == _lastDirtyCount && (CACurrentMediaTime() - _lastPushTime) < 1.0) { return; }
        _lastDirtyCount = c;
    }

    int slot = _cur;
    IOSurfaceRef surface = _surfaces[slot];
    CVPixelBufferRef pbuf = _pixelBuffers[slot];
    if (!surface || !pbuf) { return; }

    // 渲染服务器把主屏画进这块 surface。kIOSurfaceLock 不需要：渲染是同步完成的。
    _renderDisplay(0, CFSTR("LCD"), surface, 0, 0);

    // 推上一帧的槽位（双缓冲，交替）
    _cur = 1 - _cur;
    _lastPushTime = CACurrentMediaTime();

    if (self.frameHandler) { self.frameHandler(pbuf); }
}

- (BOOL)start {
    if (_running) { return YES; }
    if (![self buildSurfacesIfNeeded]) {
        NSLog(@"[capture] 起不来：surface 建失败");
        return NO;
    }
    _running = YES;
    int fps = (_fps > 0 && _fps <= 60) ? _fps : kDefaultFPS;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              NSEC_PER_SEC / fps, NSEC_PER_SEC / fps / 2);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf grabOneFrame]; });
    dispatch_resume(_timer);
    NSLog(@"[capture] 已启动 %d fps", fps);
    return YES;
}

- (void)stop {
    _running = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    for (int i = 0; i < 2; i++) {
        if (_pixelBuffers[i]) { CVPixelBufferRelease(_pixelBuffers[i]); _pixelBuffers[i] = NULL; }
        if (_surfaces[i]) { CFRelease(_surfaces[i]); _surfaces[i] = NULL; }
    }
}

@end
