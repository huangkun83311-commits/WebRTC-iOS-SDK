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
#import <VideoToolbox/VideoToolbox.h>

extern double gLastInputMono;   // AkunInjector.mm 里打点：最后一次触摸注入时刻

#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <Accelerate/Accelerate.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#import "vendor/UIScreen+Private.h"

typedef void (*RenderDisplayFn)(uint32_t ctx, CFStringRef display, IOSurfaceRef surface, int x, int y);
typedef CFIndex (*GetDirtyFrameCountFn)(void *);

static const int kDefaultFPS = 30;
/// 抓屏轮询间隔：8ms 一次「画面变了吗」。
/// 以前是 1/fps（20fps=50ms）当节拍，最坏要等 50ms 才抓一次，这就是「点了之后慢半拍」的来源；
/// 改成 8ms 轮询 + fps 闸门：变化一出现最迟 8ms 就被抓走，帧率仍被 fps 上限压住，不额外花 CPU。
static const double kPollSec = 0.002;
static const uint32_t kPixelFormatBGRA = 0x42475241;   // 'BGRA'

// 「跟手升帧」的时间戳：任何一次输入注入都会把它更新
static double gInteractMono = 0.0;

void AkunBridgeNoteInteraction(void) { gInteractMono = CACurrentMediaTime(); }

// 上一窗口的性能快照：main.mm 每 2 秒把它推给服务端，网页上就能同时看到「手机发得怎么样」
static NSDictionary *gLastMetrics = nil;
NSDictionary *AkunBridgeCaptureMetrics(void) { return gLastMetrics; }

@implementation AkunCapture {
    dispatch_queue_t _queue;
    dispatch_queue_t _paceQueue;     // 节拍专用队列：定时器只在这里排队，绝不被抓帧耗时拖住
    dispatch_semaphore_t _frameGate;// 抓帧门：上一帧还没跑完就丢掉这一拍（不排队、不追帧）
    dispatch_source_t _timer;
    BOOL _loopRunning;               // 自驱动节拍循环开关（见 frameTick）
    RenderDisplayFn _renderDisplay;
    GetDirtyFrameCountFn _dirtyFrameCount;
    CFIndex _lastDirtyCount;
    NSTimeInterval _lastPushTime;
    IOSurfaceRef _surfaces[2];
    CVPixelBufferRef _pixelBuffers[2];
    int _cur;
    CVPixelBufferRef _lastScaled;      // 上一帧缩放后的图（静态心跳复用，省掉抓屏+缩图）
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
    NSTimeInterval _lastChangeMono; // 最近一次「画面确实变了」的时刻
    NSTimeInterval _lastPushMono;
    NSTimeInterval _lastProbeMono;    // 上一次「查脏图」的时刻（静止期节流用） // 上次真正推帧的时刻（fps 闸门用）
    double _prepMsAvg;            // 准备一帧（渲染+缩图+推帧）的滑窗平均耗时，闸门提前量用
    double _costMsAvg;            // 单帧总耗时的跨窗口平均，「唤醒即发」用它判断流水线是否已空出来
    int _burstCount;              // 本窗口内「唤醒即发」的次数（用于验证这一帧真的没排队）
    double _pacePadSec;          // 已废弃（保留仅日志兼容）：节拍改由 _nextDeadline 累积
    NSTimeInterval _nextDeadline;// 下一帧应出的绝对时刻，保证平均帧率精确等于设定值
    int _idleTicks;              // 连续「画面没变」的拍数，够了才判静止
    double _dirtyMsSum;
    double _scaleGpuMsSum;       // 缩图里「GPU 那一段」的耗时合计
    int    _scaleGpuFrames;      // 走 GPU 成功的帧数
    int    _scaleCpuFrames;      // 回退 vImage 的帧数
    unsigned _dirtySkipTick;           // 节拍闭环：上一帧实际间隔与目标的差距，逐个微调
    double _pushMsSum;           // 交给 WebRTC 的耗时合计
    NSTimeInterval _perfWindowStart;
    // GPU 缩图（Core Image + Metal）：拿不到 Metal 就退回 vImage
    CIContext *_ciCtx;
    BOOL _ciFailed;
    // VideoToolbox 硬件缩放器：比 Core Image 稳定（CI 在表面被渲染服务占用时会静默掉软件路径）
    VTPixelTransferSessionRef _vtSession;
    BOOL _vtWarned;
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
        _paceQueue = dispatch_queue_create("com.akun.capture.pace", DISPATCH_QUEUE_SERIAL);
        // ★ 后台 launchd 进程默认是低 QoS，dispatch 定时器会被系统合并（实测 30 档帧距 44.9ms、
        //   60 档 40ms，跟设定值完全无关 —— 申请 2ms 实际只给 ~40ms 的闹钟）。
        //   两个队列都挂到 USER_INTERACTIVE，定时器才按申请值触发、抓帧也不被降频。
        dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        dispatch_set_target_queue(_paceQueue, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        _frameGate = dispatch_semaphore_create(1);
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
    int v = (fps >= 8 && fps <= 60) ? fps : kDefaultFPS;
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
    // 节拍恒为 8ms 轮询；fps 只作闸门（见 grabOneFrame），改 fps 不需要重建定时器精度
    (void)fps;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kPollSec * NSEC_PER_SEC), 0);
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

    // ① 首选 VideoToolbox 硬件缩放器。
    //    踩过的坑：Core Image 在「源表面正被渲染服务占用」时会静默掉到软件路径，
    //    实测一半帧掉 CPU（每帧 ~38ms），按 home 回桌面时更夸张到每帧 1 秒，
    //    表现就是「点了返回桌面要两三秒才看到画面」。VT 不吃这个。
    if (!_vtSession) {
        VTPixelTransferSessionRef sess = NULL;
        CVReturn crVT = VTPixelTransferSessionCreate(kCFAllocatorDefault, &sess);
        if (crVT == kCVReturnSuccess) { _vtSession = sess; }
        else if (!_vtWarned) { NSLog(@"[capture] VTPixelTransferSessionCreate 失败 cr=%d", (int)crVT); _vtWarned = YES; }
    }
    if (_vtSession) {
        NSTimeInterval v0 = CACurrentMediaTime();
        CVReturn vtErr = VTPixelTransferSessionTransferImage(_vtSession, src, dst);
        if (vtErr == kCVReturnSuccess) {
            _scaleGpuMsSum += (CACurrentMediaTime() - v0) * 1000.0;
            _scaleGpuFrames++;
            return dst;
        }
        if (!_vtWarned) {
            NSLog(@"[capture] VT 缩放失败 cr=%d，退回 Core Image", (int)vtErr);
            _vtWarned = YES;
        }
    }

    // ② 其次 Core Image / Metal
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
                NSTimeInterval g0 = CACurrentMediaTime();
                [ci render:scaled toCVPixelBuffer:dst
                      bounds:CGRectMake(0, 0, w, h) colorSpace:NULL];
                _scaleGpuMsSum += (CACurrentMediaTime() - g0) * 1000.0;
                _scaleGpuFrames++;
            } @catch (NSException *e) {
                static BOOL w1 = NO;
                if (!w1) { NSLog(@"[capture] GPU 缩图异常 %@，回退 vImage", e.reason); w1 = YES; }
                _ciFailed = YES; _ciCtx = nil;
            }
        }
    }

    _scaleCpuFrames++;
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

    NSTimeInterval now = CACurrentMediaTime();

    // ★ 口径：设多少就跑多少。这里先做「无条件满速」：
    //   实测这台机器 CARenderServer 的 _dirtyFrameCount 喂回来的值不可靠 ——
    //   画面明明在滑，判定却一直是「没变」，于是被 idle 节流卡到 100ms 一拍（滑动期间 10fps）。
    //   所以这一步先把脏图/idle/心跳全部绕开，只按 deadline 出帧，先证明「节拍本身能跑满」；
    //   静止降帧再用可靠手段单独补，不跟满速验证混在一起。
    int fpsNow = (_activeFps > 0) ? _activeFps : _fps;
    double interval = 1.0 / (double)MAX(1, fpsNow);
    if (_nextDeadline <= 0.0) { _nextDeadline = now; }
    if (now + 1e-4 < _nextDeadline) { return; }
    BOOL heartbeat = NO;
    const double kHeartbeatSec = 0.150;

    // ★ 节拍闭环修正已删除：改由 _nextDeadline 绝对累积（见函数开头的 timeOk 与出帧后的推进）。
    //   老 pad 修正是「距上次推帧结束的时间」，把每帧处理耗时重复计进周期，是 20fps 的病根。

    // 心跳帧：画面没变，直接把上一帧缩放结果再送一次编码器。
    // 抓屏(surface 渲染) + 缩图 一帧要 20ms，静止期每秒 6 次就是 120ms CPU；
    // 复用同一张图只剩编码器开销（实测一帧空 P 帧 2~4ms）。
    if (heartbeat && _lastScaled) {
        CVPixelBufferRef again = (CVPixelBufferRef)CVPixelBufferRetain(_lastScaled);
        if (again && self.frameHandler) { self.frameHandler(again); }
        if (again) { CVPixelBufferRelease(again); }
        _lastPushTime = CACurrentMediaTime();
        _lastPushMono = _lastPushTime;
        // 静止期下一拍就是心跳时刻（不再清 0）：自驱动循环靠这个值算该睡多久，
        // 清 0 会让它每 1ms 醒一次空转。
        _nextDeadline = _lastPushTime + kHeartbeatSec;
        _perfFrames++;              // 心跳也计一次，但下面只累加推帧耗时（其它列保持原值）
        _pushMsSum += (CACurrentMediaTime() - _lastPushTime) * 1000.0;
        [self finishPerfWindowIfNeeded:_lastPushTime];
        return;
    }

    int slot = _cur;
    IOSurfaceRef surface = _surfaces[slot];
    CVPixelBufferRef pbuf = _pixelBuffers[slot];
    if (!surface || !pbuf) { return; }

    NSTimeInterval t0 = CACurrentMediaTime();
    // 渲染服务器把主屏画进这块 surface。kIOSurfaceLock 不需要：渲染是同步完成的。
    _renderDisplay(0, CFSTR("LCD"), surface, 0, 0);
    NSTimeInterval t1 = CACurrentMediaTime();

    // 设备侧延迟分段：从触摸注入到这一帧渲染完成（不含编码/网络/客户端上屏）
    if (gLastInputMono > 0.0) {
        double d = (CACurrentMediaTime() - gLastInputMono) * 1000.0;
        gLastInputMono = 0.0;
        if (d >= 0.0 && d < 2000.0) { NSLog(@"[lat] 点击→出帧 %.1fms", d); }
    }

    // 推上一帧的槽位（双缓冲，交替）
    _cur = 1 - _cur;
    _lastPushTime = CACurrentMediaTime();
    _lastPushMono = _lastPushTime;

    // 节拍推进（必须在渲染之后、缩图之前算）：deadline 按固定 interval 累加，
    // 与这一帧花掉多少处理时间无关 → 平均帧率精确等于设定值（设 45 就跑 45）。
    // 若已经落后一整个周期（被系统卡住/主线程抢），重定基准，宁可丢帧也不连发追帧——
    // 追帧会让画面忽快忽慢，比少一帧更伤观感。
    {
        NSTimeInterval nn = CACurrentMediaTime();
        _nextDeadline += interval;
        if (_nextDeadline < nn) { _nextDeadline = nn + interval; }
    }

    CVPixelBufferRef out = [self scaleFrame:pbuf];
    NSTimeInterval t2 = CACurrentMediaTime();
    if (out) {
        if (_lastScaled) { CVPixelBufferRelease(_lastScaled); }
        _lastScaled = (CVPixelBufferRef)CVPixelBufferRetain(out);
    }
    if (out && self.frameHandler) { self.frameHandler(out); }
    if (out) { CVPixelBufferRelease(out); }
    NSTimeInterval t3 = CACurrentMediaTime();

    double prepMs = (t3 - t0) * 1000.0;
    _prepMsAvg = MIN((_prepMsAvg <= 0.0) ? prepMs : (_prepMsAvg * 0.8 + prepMs * 0.2), 60.0);
    double frameCostMs = ((t1 - t0) + (t2 - t1) + (t3 - t2)) * 1000.0;
    _costMsAvg = (_costMsAvg <= 0.0) ? frameCostMs : (_costMsAvg * 0.85 + frameCostMs * 0.15);

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
    double dirtyMs = (_perfFrames > 0) ? _dirtyMsSum / n : 0.0;
    gLastMetrics = @{@"fps" : @(realFps),
                     @"render" : @(renderMs),
                     @"scale" : @(scaleMs),
                     @"push" : @(pushMs),
                     @"dirty" : @(dirtyMs),
                     @"cost" : @(costMs),
                     @"budget" : @(budgetMs),
                     @"activeFps" : @(_activeFps),
                     @"gpuFrames" : @(_scaleGpuFrames),
                     @"cpuFrames" : @(_scaleCpuFrames),
                     @"w" : @(_poolW),
                     @"h" : @(_poolH)};
    NSString *scaleSplit = [NSString stringWithFormat:@"GPU%d帧/%.1fms CPU%d帧",
                            _scaleGpuFrames,
                            (_scaleGpuFrames > 0 ? _scaleGpuMsSum / _scaleGpuFrames : 0.0),
                            _scaleCpuFrames];
    NSLog(@"[perf] 实际 %.1ffps 取缓冲 %.1fms 渲染 %.1fms 缩图 %.1fms 推帧 %.1fms 脏图 %.1fms 合计 %.1fms / 预算 %.1fms | 缩图后端 %@ | 闸门 pad=%.1fms prep=%.1fms 帧距=%.1fms 唤醒=%d",
          realFps, allocMs, renderMs, scaleMs, pushMs, dirtyMs, costMs, budgetMs, scaleSplit,
          _pacePadSec * 1000.0, _prepMsAvg, (n > 0 ? span / n * 1000.0 : 0), _burstCount);

    _perfFrames = 0; _renderMsSum = 0; _scaleMsSum = 0; _pushMsSum = 0; _allocMsSum = 0; _burstCount = 0; _dirtyMsSum = 0;
    _scaleGpuMsSum = 0; _scaleGpuFrames = 0; _scaleCpuFrames = 0;
    _perfWindowStart = now;

    // ★ 不降帧：口径是「设 45 就跑满 45」，掉帧本身就是「顿」的来源。
    //   只有单帧耗时超过预算 3 倍且连续 6 个窗口（机器真的扛不住）才小幅降，
    //   且不低于 _fps*0.8，杜绝老实现「30 档一路掉到 20」。
    int fpsFloor = MAX(8, (int)(_fps * 0.8));
    if (costMs > budgetMs * 3.0) {
        _lowStreak++; _highStreak = 0;
        if (_lowStreak >= 6 && _activeFps > fpsFloor) {
            int v = MAX(fpsFloor, _activeFps - 2);
            _activeFps = v; _lowStreak = 0;
            [self applyTimerFps:v];
            NSLog(@"[perf] 单帧耗时 %.1fms 超预算 3 倍 %.1fms，抓屏临时降到 %d fps（真扛不住才降）", costMs, budgetMs, v);
        }
    } else if (costMs < budgetMs * 0.75) {
        _highStreak++; _lowStreak = 0;
        if (_highStreak >= 2 && _activeFps < _fps) {
            int v = MIN(_fps, _activeFps + 2);
            _activeFps = v; _highStreak = 0;
            [self applyTimerFps:v];
            NSLog(@"[perf] 余量充足，抓屏升回设定 %d fps", v);
        }
    } else {
        _lowStreak = 0; _highStreak = 0;
    }
}

- (void)frameTick {
    // ★ 节拍：自旋等到 deadline，不再依赖任何「睡到某时刻」。
    //   本机实测（同一套抓屏/编码链路，仅换节拍手段）：
    //     dispatch_source 周期定时器：申请 2ms → 实际 ~40ms（30/60 档帧距几乎一样）
    //     dispatch_after 一次性定时：请求 150ms → 实际 ~100ms
    //     mach_wait_until：请求 33ms → 实际 1173ms（这台 rootless 设备上 timebase 换算异常）
    //     nanosleep：请求 ~19ms → 实际 ~85ms（后台 daemon 的睡眠被系统按 ~100ms 粒度合并）
    //   →「睡到某时刻」在这里全部不可靠，只能用相对距离判断 + 末段自旋补齐。
    //   策略：离 deadline 还远（>2ms）就粗睡一次 2ms 让出 CPU；进入末段就自旋等到点。
    //   若一次粗睡就睡过了 deadline，就直接出帧（由 grabOneFrame 的 deadline 重基准把节奏拉回），
    //   绝不连发补帧（会卡死）。
    while (_loopRunning) {
        @autoreleasepool {
            [self grabOneFrame];
            if (!_loopRunning) { break; }
            int guard = 0;
            while (_loopRunning && (++guard) < 4000) {
                NSTimeInterval rest = _nextDeadline - CACurrentMediaTime();
                if (rest <= 0.0) { break; }
                if (rest > 0.002) {
                    // 让出 CPU 但保持 runnable：sched_yield 会立即被重新调度，
                    // 不像 nanosleep 那样被系统按 ~50ms 粒度抬（实测请求 2ms 实际 ~50ms）。
                    sched_yield();
                }
            }
        }
    }
}

- (BOOL)start {
    if (_running) { return YES; }
    if (![self buildSurfacesIfNeeded]) {
        NSLog(@"[capture] 起不来：surface 建失败");
        return NO;
    }
    _running = YES;
    // 自驱动：起一条专用线程跑节拍循环（mach_wait_until 会阻塞该线程，所以不能占用 _queue）。
    _loopRunning = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s) { [s frameTick]; }
    });
    NSLog(@"[capture] 已启动：自旋节拍（末段自旋补齐），满速（%d fps 上限）", _activeFps > 0 ? _activeFps : _fps);
    return YES;
}

- (void)stop {
    _running = NO;
    _loopRunning = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    if (_vTemp) { free(_vTemp); _vTemp = NULL; _vTempSize = 0; }
    for (int i = 0; i < 2; i++) {
        if (_pixelBuffers[i]) { CVPixelBufferRelease(_pixelBuffers[i]); _pixelBuffers[i] = NULL; }
        if (_surfaces[i]) { CFRelease(_surfaces[i]); _surfaces[i] = NULL; }
    }
}


#pragma mark - 静帧截图（中控 screenshot 指令）

- (NSData *)snapshotJPEGWithScale:(double)scale quality:(double)quality {
    return [self snapshotDataWithScale:scale quality:quality asPNG:NO];
}

- (NSData *)snapshotDataWithScale:(double)scale quality:(double)quality asPNG:(BOOL)asPNG {
    if (!_renderDisplay) { return nil; }
    CGSize sp = [self screenPixelSize];
    NSUInteger w = (NSUInteger)sp.width, h = (NSUInteger)sp.height;
    if (w == 0 || h == 0) { return nil; }
    if (scale <= 0.0) { scale = 0.5; }
    if (scale > 1.0) { scale = 1.0; }
    if (quality <= 0.0 || quality > 1.0) { quality = 0.6; }

    // 渲染服务器只认「屏幕原生尺寸」，缩放在后面走 Core Image，直接给小块尺寸会被裁掉一角。
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{},
                            (id)kCVPixelBufferWidthKey : @(w),
                            (id)kCVPixelBufferHeightKey : @(h),
                            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)attrs, &pb);
    if (cr != kCVReturnSuccess || !pb) {
        NSLog(@"[capture] 截图 CVPixelBufferCreate 失败 cr=%d", (int)cr);
        return nil;
    }
    IOSurfaceRef sf = CVPixelBufferGetIOSurface(pb);
    if (!sf) { CVPixelBufferRelease(pb); return nil; }
    _renderDisplay(0, CFSTR("LCD"), sf, 0, 0);

    CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
    if (scale < 0.999) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    }
    CIContext *ctx = [self ciContext];
    CGImageRef cg = nil;
    if (ctx) { cg = [ctx createCGImage:img fromRect:img.extent]; }
    if (!cg) {
        // 没 Metal 就退回软件渲染，慢一点但截图是低频操作
        cg = [[CIContext contextWithOptions:nil] createCGImage:img fromRect:img.extent];
    }
    CVPixelBufferRelease(pb);
    if (!cg) { return nil; }
    UIImage *ui = [UIImage imageWithCGImage:cg];
    NSData *enc = asPNG ? UIImagePNGRepresentation(ui) : UIImageJPEGRepresentation(ui, quality);
    CGImageRelease(cg);
    NSLog(@"[capture] 截图 %.0fx%.0f scale=%.2f q=%.2f %@ %luB", ui.size.width, ui.size.height,
          scale, quality, (asPNG ? @"png" : @"jpeg"), (unsigned long)enc.length);
    return enc;
}

@end
