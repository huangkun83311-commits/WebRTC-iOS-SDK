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
#import "AkunCapture.h"
#import "AkunInjector.h"
#import "AkunRTC.h"
#import "AkunDiscovery.h"

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

    // 输出参数默认对齐 AKUN 出厂值：scale 0.35 / 12fps / 1.5Mbps。
    // 这三个值决定了 30M 上行能带多少台还不卡，改之前先看 README。
    double scale = prefs[@"Scale"] ? [prefs[@"Scale"] doubleValue] : 0.35;
    int fps = prefs[@"Fps"] ? [prefs[@"Fps"] intValue] : 12;
    NSInteger maxBitrate = prefs[@"MaxBitrate"] ? [prefs[@"MaxBitrate"] integerValue] : 1500000;
    if (scale <= 0.0) { scale = 0.35; }
    if (fps <= 0) { fps = 12; }
    if (maxBitrate <= 0) { maxBitrate = 1500000; }

    NSLog(@"[daemon] server=%@ device=%@ scale=%.2f fps=%d maxBitrate=%ld",
          self.serverBase.length ? self.serverBase : @"(auto)", self.deviceId,
          scale, fps, (long)maxBitrate);

    self.injector = [[AkunInjector alloc] init];
    self.capture = [[AkunCapture alloc] init];
    self.capture.fps = fps;

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

    // 发现是异步的（广播+扫描要几秒），推流端先用占位地址起来，拿到地址后再切
    self.rtc = [[AkunRTC alloc] initWithServerBase:self.serverBase ?: @"" deviceId:self.deviceId];
    [self.rtc configureWithScale:scale fps:fps maxBitrateBps:maxBitrate];
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
                [self.injector handleCommand:cmd];
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

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[daemon] 启动 argc=%d", argc);
        AkunDaemon *daemon = [[AkunDaemon alloc] init];
        [daemon start];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
