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
#import <Accelerate/Accelerate.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
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
    // 缩图用：目标尺寸 + 缓冲池（每帧复用，不反复 malloc）
    CVPixelBufferPoolRef _pool;
    size_t _poolW, _poolH;

    // ---- 性能观测 + 帧率自适应 ----
    int _activeFps;              // 当前真正生效的抓屏帧率（可能因机器吃力被下调）
    NSUInteger _perfFrames;      // 本窗口内的帧数
    double _renderMsSum;         // 渲染（GPU 抓屏）耗时合计
    double _scaleMsSum;          // vImage 缩图耗时合计
    double _allocMsSum;          // 取池内目标缓冲的耗时合计（编码器占着池子时会卡这里）
    double _lastAllocMs;         // 本帧取缓冲耗时
    double _pushMsSum;           // 交给 WebRTC 的耗时合计
    NSTimeInterval _perfWindowStart;
    // GPU 缩图（Core Image + Metal）：拿不到 Metal 就退回 vImage
    CIContext *_ciCtx;
    BOOL _ciFailed;
    // vImage 缩放要一块临时缓冲：以前每帧传 NULL 让它内部现申请，
    // 2.7MP 源图下这笔开销就是 17ms/帧。这里按需申请一次，之后每帧复用。
    void *_vTemp;
    size_t _vTempSize;
    int _lowStreak;              // 连续「机器吃力」窗口数
    int _highStreak;             // 连续「机器轻松」窗口数
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

    // 渲染 surface 永远是「整屏原始像素」：surface 比屏幕小的时候
    // CARenderServerRenderDisplay 是裁切而不是缩放（会只看到屏幕的一个角落）。
    // 缩放改在抓帧后由 vImage 一次做完（见 scaleFrame:），然后才交给编码器。
    size_t w = (size_t)_screenWidth;
    size_t h = (size_t)_screenHeight;
    NSLog(@"[capture] 渲染面 %zux%zu（输出 scale=%.2f）", w, h, _outputScale);

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

/// 帧率热更新：以前这个属性是自动合成的，改了 _fps 但定时器还是启动时的间隔，
/// 等于「在线改 fps 不生效」。这里改成重建定时器（并清零自适应窗口）。
- (void)setFps:(int)fps {
    int v = (fps >= 8 && fps <= 30) ? fps : kDefaultFPS;
    _fps = v;
    if (v != _activeFps) {
        _activeFps = v;
        _lowStreak = 0;
        _highStreak = 0;
        if (_running) { [self applyTimerFps:v]; }
        NSLog(@"[capture] 抓屏帧率设为 %d fps", v);
    }
}

- (void)applyTimerFps:(int)fps {
    if (!_timer) { return; }
    int v = (fps >= 1 && fps <= 60) ? fps : kDefaultFPS;
    // leeway 给 0：帧间隔必须准，抖动本身就是「卡顿感」的来源
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              NSEC_PER_SEC / v, 0);
}

/// scale 只决定「缩图后的输出尺寸」，渲染 surface 始终是整屏，所以这里不用重建 surface。
/// GPU 缩图上下文：CPU 只负责下发一次绘制命令，缩放由 GPU 完成。
/// 关掉色彩管理与中间缓存：屏幕抓的是像素本身，任何色彩转换都只是白烧时间。
- (CIContext *)ciContext {
    if (_ciCtx || _ciFailed) { return _ciCtx; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { _ciFailed = YES; NSLog(@"[capture] 没有 Metal 设备，缩图走 vImage"); return nil; }
    _ciCtx = [CIContext contextWithMTLDevice:dev
                                     options:@{
        kCIContextWorkingColorSpace : [NSNull null],
        kCIContextOutputColorSpace : [NSNull null],
        kCIContextUseSoftwareRenderer : @NO,
        kCIContextCacheIntermediates : @NO,
    }];
    if (!_ciCtx) { _ciFailed = YES; NSLog(@"[capture] CIContext 创建失败，缩图走 vImage"); }
    else { NSLog(@"[capture] 缩图后端 = GPU（Core Image / Metal）"); }
    return _ciCtx;
}

- (void)setOutputScale:(double)scale {
    double s = (scale > 0.05 && scale <= 1.0) ? scale : 1.0;
    if (fabs(s - _outputScale) < 0.001) { return; }
    @synchronized (self) {
        _outputScale = s;
        NSLog(@"[capture] 输出缩放到 %.2f（渲染仍是整屏，缩图走 vImage）", s);
    }
}

#pragma mark - 抓帧

/// 把整屏大图一次性缩到目标尺寸（vImage，SIMD），并复用缓冲池。
/// 不缩的话，后面 libwebrtc 每帧要对 1242x2208 的 BGRA 做缩放+转 I420，20fps 下 CPU 直接被吃满——
/// 表现就是画面一顿一顿、点按发迟。
- (CVPixelBufferRef)scaleFrame:(CVPixelBufferRef)src CF_RETURNS_RETAINED {
    double s = (_outputScale > 0.05 && _outputScale < 0.999) ? _outputScale : 1.0;
    if (s >= 0.999) { CVPixelBufferRetain(src); return src; }

    size_t w = (size_t)lround((double)_width * s);
    size_t h = (size_t)lround((double)_height * s);
    w &= ~1UL; h &= ~1UL;
    if (w < 16 || h < 16) { CVPixelBufferRetain(src); return src; }

    if (!_pool || _poolW != w || _poolH != h) {
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (id)kCVPixelBufferWidthKey : @(w),
            (id)kCVPixelBufferHeightKey : @(h),
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)attrs, &_pool);
        _poolW = w; _poolH = h;
        // 目标尺寸变了，vImage 临时缓冲的用量也会变：让 scaleFrame 重新算一次
        if (_vTemp) { free(_vTemp); _vTemp = NULL; _vTempSize = 0; }
        NSLog(@"[capture] 缩图缓冲池 %zux%zu", w, h);
    }
    if (!_pool) { CVPixelBufferRetain(src); return src; }

    CVPixelBufferRef dst = NULL;
    NSTimeInterval ta = CACurrentMediaTime();
    CVReturn crPool = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &dst);
    _lastAllocMs = (CACurrentMediaTime() - ta) * 1000.0;
    if (crPool != kCVReturnSuccess || !dst) {
        CVPixelBufferRetain(src);
        return src;
    }

    // ① 先走 GPU：一帧 1242x2208 的 BGRA 用 CPU 缩要 15ms，GPU 只占 1~3ms 且不占 CPU
    CIContext *ci = [self ciContext];
    if (ci) {
        CIImage *si = [CIImage imageWithCVPixelBuffer:src];
        if (si) {
            CGFloat sx = (CGFloat)w / (CGFloat)si.extent.size.width;
            CGFloat sy = (CGFloat)h / (CGFloat)si.extent.size.height;
            // highQualityDownsample:YES —— 缩得干净，文字边缘才不糊
            CIImage *scaled = [[si imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)]
                               imageByCroppingToRect:CGRectMake(0, 0, w, h)];
            @try {
                [ci render:scaled toCVPixelBuffer:dst
                      bounds:CGRectMake(0, 0, w, h) colorSpace:NULL];
                return dst;
            } @catch (NSException *e) {
                static BOOL w1 = NO;
                if (!w1) { NSLog(@"[capture] GPU 缩图异常 %@，回退 vImage", e.reason); w1 = YES; }
                _ciFailed = YES; _ciCtx = nil;
            }
        }
    }

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    vImage_Buffer sb = {
        .data = CVPixelBufferGetBaseAddress(src),
        .height = CVPixelBufferGetHeight(src),
        .width = CVPixelBufferGetWidth(src),
        .rowBytes = CVPixelBufferGetBytesPerRow(src),
    };
    vImage_Buffer db = {
        .data = CVPixelBufferGetBaseAddress(dst),
        .height = CVPixelBufferGetHeight(dst),
        .width = CVPixelBufferGetWidth(dst),
        .rowBytes = CVPixelBufferGetBytesPerRow(dst),
    };
    // 目标尺寸不变时，临时缓冲大小也不变：算一次、申请一次、以后每帧复用
    if (_vTempSize == 0) {
        vImage_Error need = vImageScale_ARGB8888(&sb, &db, NULL, kvImageGetTempBufferSize);
        if (need > 0) {
            void *t = malloc((size_t)need);
            if (t) {
                _vTemp = t; _vTempSize = (size_t)need;
                NSLog(@"[capture] vImage 临时缓冲 %.2f MB（每帧复用，不再现申请）", need / 1048576.0);
            }
        }
    }
    vImage_Error err = vImageScale_ARGB8888(&sb, &db, _vTemp, kvImageNoFlags);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    if (err != kvImageNoError) {
        static BOOL warned = NO;
        if (!warned) { NSLog(@"[capture] vImageScale 失败 err=%ld，回退整屏推帧", (long)err); warned = YES; }
        CVPixelBufferRelease(dst);
        CVPixelBufferRetain(src);
        return src;
    }
    return dst;
}

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
        // 静止画面只留 2s 一次保活帧（以前是 1s）：静止时上行几乎归零，动一下立刻就有帧
        if (c == _lastDirtyCount && (CACurrentMediaTime() - _lastPushTime) < 2.0) { return; }
        _lastDirtyCount = c;
    }

    int slot = _cur;
    IOSurfaceRef surface = _surfaces[slot];
    CVPixelBufferRef pbuf = _pixelBuffers[slot];
    if (!surface || !pbuf) { return; }

    NSTimeInterval t0 = CACurrentMediaTime();
    // 渲染服务器把主屏画进这块 surface。kIOSurfaceLock 不需要：渲染是同步完成的。
    _renderDisplay(0, CFSTR("LCD"), surface, 0, 0);
    NSTimeInterval t1 = CACurrentMediaTime();

    // 推上一帧的槽位（双缓冲，交替）
    _cur = 1 - _cur;
    _lastPushTime = CACurrentMediaTime();

    CVPixelBufferRef out = [self scaleFrame:pbuf];
    NSTimeInterval t2 = CACurrentMediaTime();
    if (out && self.frameHandler) { self.frameHandler(out); }
    if (out) { CVPixelBufferRelease(out); }
    NSTimeInterval t3 = CACurrentMediaTime();

    _perfFrames++;
    _allocMsSum += _lastAllocMs;
    _renderMsSum += (t1 - t0) * 1000.0;
    _scaleMsSum  += (t2 - t1) * 1000.0;
    _pushMsSum   += (t3 - t2) * 1000.0;
    [self finishPerfWindowIfNeeded:t3];
}

/// 每 2 秒结算一次：报出渲染/缩图/推帧各占多少毫秒，以及实际帧率。
/// 同时做「机器吃力就降帧率」的自适应：帧间隔稳不住的时候，20fps 只会变成抖动，
/// 降到机器扛得住的节奏反而更顺（这也是 AKUN 在 A11 上用手感的做法）。
- (void)finishPerfWindowIfNeeded:(NSTimeInterval)now {
    NSTimeInterval span = now - _perfWindowStart;
    if (span < 2.0 || _perfFrames == 0) { return; }

    double n = (double)_perfFrames;
    double renderMs = _renderMsSum / n;
    double scaleMs = _scaleMsSum / n;
    double pushMs = _pushMsSum / n;
    double costMs = renderMs + scaleMs + pushMs;
    double realFps = n / span;
    double budgetMs = 1000.0 / (double)_activeFps;

    double allocMs = _allocMsSum / n;
    NSLog(@"[perf] 实际 %.1ffps 取缓冲 %.1fms 渲染 %.1fms 缩图 %.1fms 推帧 %.1fms 合计 %.1fms / 预算 %.1fms",
          realFps, allocMs, renderMs, scaleMs, pushMs, costMs, budgetMs);

    _perfFrames = 0; _renderMsSum = 0; _scaleMsSum = 0; _pushMsSum = 0; _allocMsSum = 0;
    _perfWindowStart = now;

    if (costMs > budgetMs * 0.7) {
        _lowStreak++; _highStreak = 0;
        if (_lowStreak >= 2 && _activeFps > 8) {
            int v = MAX(8, _activeFps - 3);
            _activeFps = v; _lowStreak = 0;
            [self applyTimerFps:v];
            NSLog(@"[perf] 单帧耗时超预算，抓屏降到 %d fps（稳帧优先）", v);
        }
    } else if (costMs < budgetMs * 0.45) {
        _highStreak++; _lowStreak = 0;
        if (_highStreak >= 3 && _activeFps < _fps) {
            int v = MIN(_fps, _activeFps + 2);
            _activeFps = v; _highStreak = 0;
            [self applyTimerFps:v];
            NSLog(@"[perf] 余量充足，抓屏升回 %d fps", v);
        }
    } else {
        _lowStreak = 0; _highStreak = 0;
    }
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
    if (_vTemp) { free(_vTemp); _vTemp = NULL; _vTempSize = 0; }
    for (int i = 0; i < 2; i++) {
        if (_pixelBuffers[i]) { CVPixelBufferRelease(_pixelBuffers[i]); _pixelBuffers[i] = NULL; }
        if (_surfaces[i]) { CFRelease(_surfaces[i]); _surfaces[i] = NULL; }
    }
}

@end
