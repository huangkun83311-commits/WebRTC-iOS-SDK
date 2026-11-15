//  AkunBridge daemon — 手机侧常驻进程
//
//  与 IPA 那套（ReplayKit 扩展 + App）的差别：
//    1. 它是 /usr/bin 下的独立进程，由 LaunchDaemon 以 mobile 用户常驻拉起；
//    2. 抓屏走 IOMobileFramebuffer/IOSurface，不需要用户手动开「屏幕录制」；
//    3. 能注入 HID 事件（依赖 entitlements 里的 hid.client.event-dispatch），
//       所以电脑端点击、滑动、回桌面都能作用到整个系统，而不只是自己这个 App。
//
//  服务地址默认不用手填：配置里 ServerBase 留空（或写 auto）就走局域网自动发现，
//  先 UDP 19951 广播、失败再扫 /24 网段的 8080，和 AKUN 那套的发现习惯一致。

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>
#import "AkunCapture.h"
#import "AkunInjector.h"
#import "AkunRTC.h"
#import "AkunDiscovery.h"
#import "AkunOrientation.h"

static NSString *kPrefsPathLegacy = @"/var/mobile/Library/Preferences/com.akun.bridge.plist";
static NSString *kPrefsPathRootless = @"/var/jb/var/mobile/Library/Preferences/com.akun.bridge.plist";

@interface AkunDaemon : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) AkunCapture *capture;
@property (nonatomic, strong) AkunInjector *injector;
@property (nonatomic, strong) AkunRTC *rtc;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *ctrlTask;
@property (nonatomic, copy) NSString *serverBase;
@property (nonatomic, copy) NSString *deviceId;
@property (nonatomic, assign) BOOL autoDiscover;
@property (nonatomic, assign) BOOL discovering;
@property (nonatomic, assign) NSInteger reconnectAttempt;
@property (nonatomic, assign) uint64_t frameCount;
// 当前生效的画质参数（AkunRTC 的 scale/targetFps/maxBitrateBps 没公开，这里自己存一份给 cfg 指令做基线）
@property (nonatomic, assign) double cfgScale;
@property (nonatomic, assign) int cfgFps;
@property (nonatomic, assign) NSInteger cfgBitrate;
@end

@implementation AkunDaemon

- (NSDictionary *)loadPrefs {
    NSArray *paths = @[kPrefsPathRootless, kPrefsPathLegacy];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) {
            NSLog(@"[daemon] 配置来自 %@", p);
            return d;
        }
    }
    NSLog(@"[daemon] 没读到配置文件，走全默认（自动发现）");
    return @{};
}

#pragma mark - 地址解析（自动发现）

- (void)resolveServerIfNeeded {
    NSString *configured = self.serverBase ?: @"";
    BOOL needDiscover = (configured.length == 0 ||
                         [configured.lowercaseString isEqualToString:@"auto"]);
    self.autoDiscover = needDiscover;

    if (!needDiscover) {
        NSLog(@"[daemon] 使用配置里的固定地址 %@", configured);
        return;
    }
    if (self.discovering) {
        NSLog(@"[daemon] 正在发现中，跳过重复探测");
        return;
    }

    self.discovering = YES;
    NSLog(@"[daemon] 开始局域网自动发现");
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *found = [AkunDiscovery discoverServerWithTimeout:3.0];
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        self.discovering = NO;
        if (found.length) {
            self.serverBase = found;
            NSLog(@"[daemon] 自动发现成功：%@", found);
        } else {
            NSLog(@"[daemon] 自动发现失败，等下一轮重试");
        }
    });
}

- (NSString *)ctrlURLString {
    NSString *base = self.serverBase ?: @"";
    if ([base hasPrefix:@"http://"]) {
        base = [@"ws://" stringByAppendingString:[base substringFromIndex:7]];
    } else if ([base hasPrefix:@"https://"]) {
        base = [@"wss://" stringByAppendingString:[base substringFromIndex:8]];
    }
    while ([base hasSuffix:@"/"]) {
        base = [base substringToIndex:base.length - 1];
    }
    return [NSString stringWithFormat:@"%@/ws?room=ctrl-%@&role=subscriber", base, self.deviceId];
}

#pragma mark - 启动

- (void)start {
    NSDictionary *prefs = [self loadPrefs];
    self.serverBase = prefs[@"ServerBase"] ?: @"";
    self.deviceId = prefs[@"DeviceId"] ?: @"dev001";

    // 输出参数默认值：scale 跟 AKUN 出厂一致（0.35，字体清晰度等同 AKUN），
    // 需要更清晰或更省流量时，不改包、走 /api/config 在线下发档位即可。
    // fps 直接决定操作手感（帧间隔就是最低延迟）：25fps=40ms，20fps=50ms。
    // 抓屏吃力时会由 AkunCapture 的帧率自适应往下退，所以这里可以给到 25。
    double scale = prefs[@"Scale"] ? [prefs[@"Scale"] doubleValue] : 0.35;
    int fps = prefs[@"Fps"] ? [prefs[@"Fps"] intValue] : 30;
    NSInteger maxBitrate = prefs[@"MaxBitrate"] ? [prefs[@"MaxBitrate"] integerValue] : 900000;
    if (scale <= 0.0) { scale = 0.35; }
    if (fps <= 0) { fps = 30; }
    if (maxBitrate <= 0) { maxBitrate = 900000; }

    NSLog(@"[daemon] server=%@ device=%@ scale=%.2f fps=%d maxBitrate=%ld",
          self.serverBase.length ? self.serverBase : @"(auto)", self.deviceId,
          scale, fps, (long)maxBitrate);

    self.cfgScale = scale; self.cfgFps = fps; self.cfgBitrate = maxBitrate;

    self.injector = [[AkunInjector alloc] init];
    self.capture = [[AkunCapture alloc] init];
    self.capture.fps = fps;
    // 抓屏按「整屏原始像素」渲染（surface 小于屏幕时 CARenderServer 是裁切不是缩放），
    // 缩图由抓屏层用 vImage 一次做完，编码器只管编码 → 省下每帧一次 2.7MP 的缩放+转码，卡顿的主要来源。
    self.capture.outputScale = scale;
    __weak typeof(self) weakSelf = self;
    self.capture.frameHandler = ^(CVPixelBufferRef pixelBuffer) {
        weakSelf.frameCount++;
        if (weakSelf.frameCount % 60 == 0) {
            NSLog(@"[daemon] frames=%llu %zux%zu", weakSelf.frameCount,
                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
        }
        [weakSelf.rtc pushPixelBuffer:pixelBuffer];
    };

    [self resolveServerIfNeeded];

    // 跟随设备旋转（FBSOrientationObserver，跟 AKUN 一样）；拿不到这个类就固定竖屏
    [AkunOrientation startObserving];

    // 发现是异步的（广播+扫描要几秒），推流端先用占位地址起来，拿到地址后再切
    self.rtc = [[AkunRTC alloc] initWithServerBase:self.serverBase ?: @"" deviceId:self.deviceId];
    // 自适应降档时只改抓屏缩图比例，编码器那边自动跟着重算输出尺寸
    self.rtc.adaptiveScaleHandler = ^(double s) {
        __strong typeof(weakSelf) strong = weakSelf;
        if (!strong) { return; }
        [strong.capture setOutputScale:s];
    };
    // 输入已经是缩好的小图，编码器侧 scale 用 1.0，避免二次缩放（多一道缩放既糊又费 CPU）
    [self.rtc configureWithScale:1.0 fps:fps maxBitrateBps:maxBitrate];
    // 自适应基线 = 用户/中控设定的清晰度与码率上限，自适应只往下动
    [self.rtc setAdaptiveBaseScale:scale bitrate:maxBitrate];
    [self.rtc start];

    if (![self.capture start]) {
        NSLog(@"[daemon] 抓屏启动失败");
    }
    [self connectCtrl];

    // 定时器：还没拿到地址就继续找；拿到之后把 rtc / 控制通道切过去
    [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [t invalidate]; return; }
        if (self.autoDiscover && self.serverBase.length == 0) {
            [self resolveServerIfNeeded];
            return;
        }
        if (self.autoDiscover && self.serverBase.length) {
            [self.rtc reconnectWithServerBase:self.serverBase];
            [self connectCtrl];
            self.autoDiscover = NO;   // 只在首次发现后切一次
        }
    }];
}

#pragma mark - 控制通道

- (void)connectCtrl {
    if (self.serverBase.length == 0) {
        NSLog(@"[daemon] 还没有服务地址，控制通道暂不连接");
        return;
    }
    NSString *urlString = [self ctrlURLString];
    NSLog(@"[daemon] 连接控制通道 %@", urlString);
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { return; }

    if (!self.session) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }

    [self.ctrlTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.ctrlTask = [self.session webSocketTaskWithURL:url];
    [self.ctrlTask resume];
    [self receiveLoopOn:self.ctrlTask];
}

- (void)receiveLoopOn:(NSURLSessionWebSocketTask *)task {
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        if (error) {
            NSLog(@"[daemon] 控制通道断开: %@", error.localizedDescription);
            [self scheduleReconnect];
            return;
        }
        NSData *data = nil;
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
        } else if (message.type == NSURLSessionWebSocketMessageTypeData) {
            data = message.data;
        }
        if (data) {
            NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([cmd isKindOfClass:[NSDictionary class]]) {
                NSString *type = cmd[@"t"];
                if ([type isEqualToString:@"ping"]) {
                    // 只测控制链路往返，不触发任何动作
                    NSDictionary *pong = @{@"t" : @"pong", @"ts" : cmd[@"ts"] ?: @0};
                    NSData *d = [NSJSONSerialization dataWithJSONObject:pong options:0 error:nil];
                    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                    [self.ctrlTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:s]
                              completionHandler:^(NSError *e) {}];
                } else if ([type isEqualToString:@"cfg"]) {
                    // 中控/网页在线改画质，不用重装包
                    double scale = self.cfgScale;
                    int fps = self.cfgFps;
                    NSInteger br = self.cfgBitrate;
                    if (cmd[@"scale"]) { scale = [cmd[@"scale"] doubleValue]; }
                    if (cmd[@"fps"]) { fps = [cmd[@"fps"] intValue]; }
                    if (cmd[@"bitrate"]) { br = [cmd[@"bitrate"] integerValue]; }
                    // 下限保护：scale 再低字就糊了（0.30 ≈ 372x662），宁可降帧也不降到这里以下
                    if (scale < 0.30) { scale = 0.30; }
                    if (scale > 1.0) { scale = 1.0; }
                    if (fps < 8) { fps = 8; }
                    if (fps > 30) { fps = 30; }
                    NSLog(@"[ctrl] 在线改画质 scale=%.2f fps=%d bitrate=%ld", scale, fps, (long)br);
                    // 缩图在抓屏层（vImage，整屏渲染 + 一次性缩到目标尺寸），编码器不再缩放
                    [self.capture setOutputScale:scale];
                    [self.rtc configureWithScale:1.0 fps:fps maxBitrateBps:br];
                    [self.rtc setAdaptiveBaseScale:scale bitrate:br];
                    self.cfgScale = scale; self.cfgFps = fps; self.cfgBitrate = br;
                    [self.capture setFps:fps];
                } else {
                    NSLog(@"[ctrl] 收到 %@", message.string ?: @"<bin>");
                    [self.injector handleCommand:cmd];
                }
            }
        }
        [self receiveLoopOn:task];
    }];
}

- (void)scheduleReconnect {
    self.reconnectAttempt++;
    double delay = MIN(pow(2.0, (double)self.reconnectAttempt), 30.0);
    NSLog(@"[daemon] %0.1fs 后重连（第 %ld 次）", delay, (long)self.reconnectAttempt);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        [self reconnectNow];
    });
}

/// 断线重连：如果本来就是自动发现模式，先重新找地址（换了网络/电脑换了 IP 也能自愈）。
- (void)reconnectNow {
    NSString *configured = self.serverBase ?: @"";
    BOOL autoMode = (configured.length == 0 ||
                     [configured.lowercaseString isEqualToString:@"auto"]);
    if (autoMode) {
        NSLog(@"[daemon] 重连前重新发现服务");
        NSString *found = [AkunDiscovery discoverServerWithTimeout:2.0];
        if (found.length) {
            self.serverBase = found;
            [self.rtc reconnectWithServerBase:found];
        }
    }
    [self connectCtrl];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
didOpenWithProtocol:(NSString *)protocol {
    NSLog(@"[daemon] 控制通道已连接");
    self.reconnectAttempt = 0;
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    NSLog(@"[daemon] 控制通道关闭 code=%ld", (long)code);
    if (code != NSURLSessionWebSocketCloseCodeGoingAway) {
        [self scheduleReconnect];
    }
}

@end

#pragma mark - jetsam 上限（launchd 起默认只有 6MB，抓屏建 surface 立刻被系统杀）

#define kMemStatSetHighWaterMark 5   // 非致命上限
#define kMemStatSetTaskLimit     6   // 致命上限

static void AkunRaiseJetsamLimit(void) {
    void *sym = dlsym(RTLD_DEFAULT, "memorystatus_control");
    NSLog(@"[jetsam] memorystatus_control=%p", sym);
    if (!sym) {
        return;
    }
    typedef int (*MemStatFn)(uint32_t, int32_t, uint32_t, void *, size_t);
    MemStatFn fn = (MemStatFn)sym;
    int32_t pid = (int32_t)getpid();
    int rcHigh = fn(kMemStatSetHighWaterMark, pid, 0, NULL, 400);
    int rcTask = fn(kMemStatSetTaskLimit, pid, 0, NULL, 400);
    NSLog(@"[jetsam] 抬到 400MB: highWaterMark rc=%d taskLimit rc=%d", rcHigh, rcTask);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 调试入口：`akund --tap 0.5 0.5` / `akund --key 233`，直接调注入器并退出。
        // 这样在 SSH 里跑能看到崩溃信息（守护态下崩溃只能看到进程消失）。
        if (argc >= 2 && strcmp(argv[1], "--tap") == 0) {
            AkunInjector *inj = [[AkunInjector alloc] init];
            double x = (argc > 3) ? atof(argv[2]) : 0.5;
            double y = (argc > 3) ? atof(argv[3]) : 0.5;
            NSLog(@"[cli] tap %f %f", x, y);
            [inj handleCommand:@{@"t" : @"tap", @"x" : @(x), @"y" : @(y)}];
            sleep(2);
            NSLog(@"[cli] tap 返回（没崩溃）");
            return 0;
        }
        if (argc >= 2 && strcmp(argv[1], "--key") == 0) {
            AkunInjector *inj = [[AkunInjector alloc] init];
            unsigned int usage = (argc > 2) ? (unsigned int)strtoul(argv[2], NULL, 0) : 0xE9;
            NSLog(@"[cli] key 0x%x", usage);
            [inj handleCommand:@{@"t" : @"hk", @"usage" : @(usage)}];
            sleep(2);
            NSLog(@"[cli] key 返回（没崩溃）");
            return 0;
        }
        NSLog(@"[daemon] 启动 argc=%d", argc);
        AkunRaiseJetsamLimit();
        AkunDaemon *daemon = [[AkunDaemon alloc] init];
        [daemon start];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
