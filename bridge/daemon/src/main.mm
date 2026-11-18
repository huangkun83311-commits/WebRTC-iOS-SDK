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
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <errno.h>
#import <dirent.h>
#import <sys/stat.h>
#import <spawn.h>
#import <sys/wait.h>
#import <signal.h>
#import <UIKit/UIKit.h>
extern char **environ;
#import <sys/sysctl.h>
// 注意：不要 extern 声明 proc_listpids/proc_pidpath —— 链接期绑定会在 iOS 上
// 报 "dyld: missing symbol called" 直接把 dpkgd 打死（已实测踩过）。
// 找 SpringBoard 改用 sysctl(KERN_PROC_ALL) 遍历进程表，零外部依赖。
#import "AkunCapture.h"
extern void AkunBridgeNoteInteraction(void);   // 抓屏层：进交互窗口，下一拍强制出帧
#import "AkunInjector.h"
#import "AkunRTC.h"
#import "AkunDiscovery.h"
#import "AkunOrientation.h"

static NSString *kPrefsPathLegacy = @"/var/mobile/Library/Preferences/com.akun.bridge.plist";
static NSString *kPrefsPathRootless = @"/var/jb/var/mobile/Library/Preferences/com.akun.bridge.plist";

extern NSDictionary *AkunBridgeCaptureMetrics(void);
extern NSDictionary *AkunBridgeRtcMetrics(void);

@interface AkunDaemon : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) AkunCapture *capture;
@property (nonatomic, strong) AkunInjector *injector;
@property (nonatomic, strong) AkunRTC *rtc;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *ctrlTask;
@property (nonatomic, assign) NSInteger burstGen;
@property (nonatomic, copy) NSString *serverBase;
@property (nonatomic, copy) NSString *deviceId;
@property (nonatomic, assign) BOOL autoDiscover;
@property (nonatomic, assign) BOOL discovering;
@property (nonatomic, assign) NSInteger reconnectAttempt;
@property (nonatomic, assign) uint64_t frameCount;
@property (nonatomic, assign) double kickAtMono;   // 收到 kickframe 的时刻（量首帧用）
// 当前生效的画质参数（AkunRTC 的 scale/targetFps/maxBitrateBps 没公开，这里自己存一份给 cfg 指令做基线）
@property (nonatomic, assign) double cfgScale;
@property (nonatomic, assign) int cfgFps;
@property (nonatomic, assign) NSInteger cfgBitrate;
// 单台硬上限（含突发窗口）：0 表示不限。用户要求"单台最高 1.2M/1.5M"时由中控下发 cap=…
@property (nonatomic, assign) NSInteger cfgHardCap;
@end

// 与 AKUN 完全一致的 UDP 发现：19941 上收 13 字节探测包
// （4 字节大端魔数 "AKUN" + 1 字节版本 + 8 字节 nonce），回一条 JSON。
// 字段照抄 AKUN：m/u/n/p/c/s/v，另外多给 w（本机 WebRTC 信令的 HTTP 地址）
// 与 r（协议类型），这样中控既能像以前那样按 19941 找到机器，也知道这次不是 RFB。
static NSString *AkunLocalIPv4(void) {
    NSString *best = nil;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || !list) { return nil; }
    for (struct ifaddrs *it = list; it; it = it->ifa_next) {
        if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET) { continue; }
        if (!(it->ifa_flags & IFF_UP) || (it->ifa_flags & IFF_LOOPBACK)) { continue; }
        NSString *name = [NSString stringWithUTF8String:it->ifa_name];
        struct sockaddr_in *sin = (struct sockaddr_in *)it->ifa_addr;
        NSString *ip = [NSString stringWithUTF8String:inet_ntoa(sin->sin_addr)];
        if (!ip.length) { continue; }
        if ([name isEqualToString:@"en0"]) { best = ip; break; }
        if (!best) { best = ip; }
    }
    freeifaddrs(list);
    return best;
}

@interface AkunDiscoveryUDP : NSObject
@end

@implementation AkunDiscoveryUDP
- (void)run {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { NSLog(@"[discovery] socket 创建失败"); return; }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    int rcvBuf = 32 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, sizeof(rcvBuf));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(19941);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    int logged = 0;
    while (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        // 19941 被 AKUN 的 VNC 插件占着时只能等：AKUN 停了或卸了，我们立刻接手，
        // 同一台机器上两个插件不为同一个发现端口互相抢。
        if (!logged++) { NSLog(@"[discovery] 19941 被占用（AKUN 在跑？）errno=%d，每 15 秒重试", errno); }
        sleep(15);
    }
    NSLog(@"[discovery] 已在 UDP 19941 监听（与 AKUN 同协议）");

    uint8_t packet[128];
    while (1) {
        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        ssize_t n = recvfrom(fd, packet, sizeof(packet), 0, (struct sockaddr *)&peer, &peerLen);
        if (n < 13) { continue; }
        uint32_t magic = 0;
        memcpy(&magic, packet, sizeof(magic));
        if (ntohl(magic) != 0x414B554Eu) { continue; }   // 不是 AKUN 协议，静默丢弃

        @autoreleasepool {
            NSString *udid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
            NSString *name = [[UIDevice currentDevice] name];
            NSDictionary *sysInfo = [NSDictionary dictionaryWithContentsOfFile:
                @"/System/Library/CoreServices/SystemVersion.plist"];
            NSString *sysVersion = sysInfo[@"ProductVersion"];
            if (!sysVersion.length) { sysVersion = [[UIDevice currentDevice] systemVersion]; }

            NSMutableDictionary *reply = [NSMutableDictionary dictionary];
            reply[@"m"] = @"AKUN";          // 中控按 m 认设备，保持一致
            if (udid.length) { reply[@"u"] = udid; }
            if (name.length) { reply[@"n"] = name; }
            reply[@"p"] = @0;               // 本插件没有 5901 RFB
            reply[@"c"] = @0;               // 也没有 19940 裸 TCP，控制走下面的 w
            reply[@"v"] = @"1.0.0";
            reply[@"r"] = @"webrtc";
            if (sysVersion.length) { reply[@"s"] = sysVersion; }
            NSString *ip = AkunLocalIPv4();
            if (ip.length) { reply[@"w"] = [NSString stringWithFormat:@"http://%@:8080", ip]; }

            NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
            if (json.length) {
                sendto(fd, json.bytes, json.length, 0, (struct sockaddr *)&peer, sizeof(peer));
            }
        }
    }
}
@end

// 轻量 TCP 探测：给自动发现做「上次地址还活着吗」的判断，不建连接池
static BOOL akun_tcp_reachable(NSString *host, int port, double timeoutSec) {
    if (host.length == 0 || port <= 0) return NO;
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    sa.sin_addr.s_addr = inet_addr(host.UTF8String);
    if (sa.sin_addr.s_addr == INADDR_NONE) return NO;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    if (rc == 0) { close(fd); return YES; }
    if (errno != EINPROGRESS) { close(fd); return NO; }
    struct timeval tv;
    tv.tv_sec = (time_t)timeoutSec;
    tv.tv_usec = (int)((timeoutSec - (double)tv.tv_sec) * 1000000);
    fd_set ws, es;
    FD_ZERO(&ws); FD_SET(fd, &ws);
    FD_ZERO(&es); FD_SET(fd, &es);
    BOOL ok = NO;
    if (select(fd + 1, &ws, NULL, &es, &tv) > 0) {
        int err = 0; size_t elen = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, (socklen_t *)&elen);
        ok = (err == 0);
    }
    close(fd);
    return ok;
}

@implementation AkunDaemon

- (NSArray<NSString *> *)statePaths {
    return @[ @"/var/mobile/Library/Caches/akun-bridge-state.plist",
              @"/var/jb/var/mobile/Library/Caches/akun-bridge-state.plist",
              @"/var/mobile/Documents/akun-bridge-state.plist",
              @"/tmp/akun-bridge-state.plist" ];
}

- (NSDictionary *)loadState {
    for (NSString *p in [self statePaths]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) { NSLog(@"[cfg] 读到上次保存的参数 %@", p); return d; }
    }
    return @{};
}

- (void)saveState {
    // 先读回现有内容再合并 —— 否则会把 lastServer 这类字段一起覆盖掉
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[self loadState]];
    d[@"scale"] = @(self.cfgScale);
    d[@"fps"] = @(self.cfgFps);
    d[@"bitrate"] = @(self.cfgBitrate);
    d[@"cap"] = @(self.cfgHardCap);
    for (NSString *p in [self statePaths]) {
        if (![d writeToFile:p atomically:YES]) { continue; }
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) { continue; }
        NSLog(@"[cfg] 参数已落盘 %@ scale=%.2f fps=%d bitrate=%ld cap=%ld", p,
              self.cfgScale, self.cfgFps, (long)self.cfgBitrate, (long)self.cfgHardCap);
        return;
    }
    NSLog(@"[cfg] 参数落盘失败（下次重启会回到默认值）");
}

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

    // 0) 先试上次成功过的地址：重启 daemon 后 1~2 秒就能连回来，不用等扫网段
    NSString *last = [self loadState][@"lastServer"];
    if (last.length) {
        NSString *h = last;
        if ([h hasPrefix:@"http://"]) h = [h substringFromIndex:7];
        else if ([h hasPrefix:@"https://"]) h = [h substringFromIndex:8];
        NSString *ip = h;
        int port = 8080;
        NSRange c = [h rangeOfString:@":"];
        if (c.location != NSNotFound) {
            ip = [h substringToIndex:c.location];
            port = [[h substringFromIndex:c.location + 1] intValue];
        }
        if (akun_tcp_reachable(ip, port, 1.2)) {
            self.serverBase = last;
            NSLog(@"[daemon] 上次地址仍可用，直接复用：%@", last);
            return;
        }
        NSLog(@"[daemon] 上次地址 %@ 不通，转入扫描", last);
    }

    self.discovering = YES;
    // UDP 19941 发现应答（与 AKUN 同协议，中控不需要改扫描逻辑）
    AkunDiscoveryUDP *udp = [[AkunDiscoveryUDP alloc] init];
    [NSThread detachNewThreadSelector:@selector(run) toTarget:udp withObject:nil];

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
            // 记下来：下次重启（含 restart_daemon）直接复用，不再扫网段
            NSDictionary *st = [self loadState];
            if (![st[@"lastServer"] isEqualToString:found]) {
                self.cfgHardCap = self.cfgHardCap;   // 保持参数不变
                [self saveState];
                NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[self loadState]];
                d[@"lastServer"] = found;
                for (NSString *p in [self statePaths]) {
                    if ([d writeToFile:p atomically:YES] &&
                        [[NSFileManager defaultManager] fileExistsAtPath:p]) {
                        NSLog(@"[daemon] 记住服务端地址 %@", found);
                        break;
                    }
                }
            }
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
    } else if (base.length && ![base hasPrefix:@"ws://"] && ![base hasPrefix:@"wss://"]) {
        base = [@"ws://" stringByAppendingString:base];
    }
    while ([base hasSuffix:@"/"]) {
        base = [base substringToIndex:base.length - 1];
    }
    return [NSString stringWithFormat:@"%@/ws?room=ctrl-%@&role=subscriber", base, self.deviceId];
}

#pragma mark - 启动

- (void)start {
    NSDictionary *prefs = [self loadPrefs];
    NSString *rawBase = prefs[@"ServerBase"] ?: @"";
    // "auto" 是「留空自动发现」的写法，绝不能当成 host 直接拼进 ws URL
    if ([[rawBase lowercaseString] isEqualToString:@"auto"]) rawBase = @"";
    self.serverBase = rawBase;
    self.deviceId = prefs[@"DeviceId"] ?: @"dev001";

    // 输出参数默认值：scale 跟 AKUN 出厂一致（0.35，字体清晰度等同 AKUN），
    // 需要更清晰或更省流量时，不改包、走 /api/config 在线下发档位即可。
    // 帧率不是越高越好：A11 单帧管道约 19ms，硬拉到 45fps 会把 CPU 长期占满，
    // 十几分钟后热降频，反而「越用越卡」。30fps 是这台机器的稳态甜点：
    // 帧距 34ms、单帧占空 ~60%，长时间跑不掉帧、不烫手。
    // 需要更跟手时网页档位可以现场提到 45/60，掉下来由自适应兜底（保底 24fps）。
    double scale = prefs[@"Scale"] ? [prefs[@"Scale"] doubleValue] : 0.35;
    int fps = prefs[@"Fps"] ? [prefs[@"Fps"] intValue] : 30;
    NSInteger maxBitrate = prefs[@"MaxBitrate"] ? [prefs[@"MaxBitrate"] integerValue] : 700000;
    // 上一次"主动下发"的参数存在 /var/mobile/Library/Caches/akun-bridge-state.plist，
    // 重启/重装插件后优先用它，这样你设一次就一直生效，不需要每次再发。
    NSDictionary *state = [self loadState];
    NSInteger savedCap = 0;
    if (state[@"scale"]) { scale = [state[@"scale"] doubleValue]; }
    if (state[@"fps"]) { fps = [state[@"fps"] intValue]; }
    if (state[@"bitrate"]) { maxBitrate = [state[@"bitrate"] integerValue]; }
    if (state[@"cap"]) { savedCap = [state[@"cap"] integerValue]; }
    if (state.count) { NSLog(@"[daemon] 用上次保存的参数 scale=%.2f fps=%d bitrate=%ld cap=%ld", scale, fps, (long)maxBitrate, (long)savedCap); }

    if (scale <= 0.0) { scale = 0.35; }
    if (fps <= 0) { fps = 30; }
    if (fps > 60) { fps = 60; }
    if (maxBitrate <= 0) { maxBitrate = 700000; }

    NSLog(@"[daemon] server=%@ device=%@ scale=%.2f fps=%d maxBitrate=%ld",
          self.serverBase.length ? self.serverBase : @"(auto)", self.deviceId,
          scale, fps, (long)maxBitrate);

    self.cfgScale = scale; self.cfgFps = fps; self.cfgBitrate = maxBitrate;
    self.cfgHardCap = savedCap;

    self.injector = [[AkunInjector alloc] init];
    self.capture = [[AkunCapture alloc] init];
    self.injector.capture = self.capture;   // 截图指令用采集层渲染，弱引用
    self.capture.fps = fps;
    // 抓屏按「整屏原始像素」渲染（surface 小于屏幕时 CARenderServer 是裁切不是缩放），
    // 缩图由抓屏层用 vImage 一次做完，编码器只管编码 → 省下每帧一次 2.7MP 的缩放+转码，卡顿的主要来源。
    self.capture.outputScale = scale;
    __weak typeof(self) weakSelf = self;
    // 每 2 秒把设备侧真实指标推到控制房间：网页（以及我）就能同时看到
    // 「手机这边发得怎么样」和「浏览器那边收得怎么样」，排障不用两头猜。
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        NSDictionary *cap = AkunBridgeCaptureMetrics();
        NSDictionary *rtc = AkunBridgeRtcMetrics();
        if (!cap || !rtc) { return; }
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        m[@"t"] = @"metrics";
        m[@"cap"] = cap;
        m[@"rtc"] = rtc;
        m[@"cfg"] = @{@"fps" : @(self.cfgFps), @"scale" : @(self.cfgScale),
                         @"bitrate" : @(self.cfgBitrate), @"cap" : @(self.cfgHardCap)};
        NSData *d = [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
        if (!d) { return; }
        NSString *js = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        NSURLSessionWebSocketTask *task = self.ctrlTask;
        if (task && task.state == NSURLSessionTaskStateRunning) {
            [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:js]
             completionHandler:^(NSError *e) {}];
        }
    }];
    self.capture.frameHandler = ^(CVPixelBufferRef pixelBuffer) {
        weakSelf.frameCount++;
        if (weakSelf.kickAtMono > 0.0) {
            // 从「服务端说有人要看」到「第一帧交进编码器」的真实耗时。
            NSLog(@"[kick] 喊到首帧 %.1fms", (CACurrentMediaTime() - weakSelf.kickAtMono) * 1000.0);
            weakSelf.kickAtMono = 0.0;
        }
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

/// 用户一动手就放开码率上限：整屏变化的那一帧有几万字节，
/// 700kbps 要发半秒，抬到 4 倍后只要 100 多毫秒；停手 0.8 秒自动收回。
/// 窗口只留 0.8s 是因为大帧通常 1~2 帧就发完了，抬久了纯属白烧流量：
/// 原来 1.5s 窗口在"连点"场景下几乎常驻高位（用户看到 3.4Mbps），
/// 收到 0.8s 后单次交互的平均计入流量少一半，跟手一点没变。
- (void)kickBurstForInteraction {
    NSInteger base = self.cfgBitrate > 0 ? self.cfgBitrate : 700000;
    NSInteger burst = base * 4;
    if (burst < 3000000) { burst = 3000000; }
    if (burst > 8000000) { burst = 8000000; }
    // 单台硬上限：中控要求"每台最多 1.2M/1.5M"时，突发也不许越过它，
    // 这样 20~30 台叠加才压得住 30M 上行；cap=0 表示不限（单台局域网看最跟手）。
    if (self.cfgHardCap > 0 && burst > self.cfgHardCap) { burst = self.cfgHardCap; }
    [self.rtc setBurstBitrateBps:burst];
    self.burstGen += 1;
    NSInteger gen = self.burstGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen == self.burstGen) { [self.rtc endBurstBitrate]; }
    });
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
                NSString *act = cmd[@"action"];
                // AKUN 19940 风格裸 JSON：{"action":"list_apps"} → 回 {"success":...}
                // 中控的辅助功能模块一行都不用改，只把发送通道从 19940 换成我们的 WS。
                if (act.length) {
                    {
                        NSMutableDictionary *res2 = [NSMutableDictionary dictionaryWithDictionary:
                            [self.injector handleAux:cmd] ?: @{ @"success" : @NO }];
                        res2[@"version"] = @"1.0.0";
                        NSData *d2 = [NSJSONSerialization dataWithJSONObject:res2 options:0 error:nil];
                        NSString *s2 = [[NSString alloc] initWithData:d2 encoding:NSUTF8StringEncoding];
                        NSLog(@"[aux] %@ -> %@", act, res2[@"success"]);
                        [self.ctrlTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:s2]
                                  completionHandler:^(NSError *e) {}];
                    }
                } else if ([type isEqualToString:@"kickframe"]) {
                    // 有人打开观看端（或手机重连上来）时服务端会喊这一声。
                    // 静止画面下抓屏层 2 秒才保活一帧，新观众就得黑屏 1~2 秒；
                    // 这里当成一次"交互"处理：下一拍立刻出帧，首屏从秒级降到几十毫秒。
                    AkunBridgeNoteInteraction();
                    self.kickAtMono = CACurrentMediaTime();
                    NSLog(@"[rtc] kickframe：新观众进来，立刻出帧");
                } else if ([type isEqualToString:@"ping"]) {
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
                    NSInteger cap = self.cfgHardCap;
                    if (cmd[@"scale"]) { scale = [cmd[@"scale"] doubleValue]; }
                    if (cmd[@"fps"]) { fps = [cmd[@"fps"] intValue]; }
                    if (cmd[@"bitrate"]) { br = [cmd[@"bitrate"] integerValue]; }
                    if (cmd[@"cap"]) { cap = [cmd[@"cap"] integerValue]; }
                    if (cap > 0 && cap < br) { br = cap; }   // 硬上限低于基线时，基线也跟着降
                    // 下限保护：scale 再低字就糊了（0.30 ≈ 372x662），宁可降帧也不降到这里以下
                    if (scale < 0.30) { scale = 0.30; }
                    if (scale > 1.0) { scale = 1.0; }
                    if (fps < 8) { fps = 8; }
                    if (fps > 60) { fps = 60; }
                    NSLog(@"[ctrl] 在线改画质 scale=%.2f fps=%d bitrate=%ld cap=%ld", scale, fps, (long)br, (long)cap);
                    // 缩图在抓屏层（vImage，整屏渲染 + 一次性缩到目标尺寸），编码器不再缩放
                    [self.capture setOutputScale:scale];
                    [self.rtc configureWithScale:1.0 fps:fps maxBitrateBps:br];
                    [self.rtc setAdaptiveBaseScale:scale bitrate:br];
                    self.cfgScale = scale; self.cfgFps = fps; self.cfgBitrate = br; self.cfgHardCap = cap;
                    [self.capture setFps:fps];
                    [self saveState];
                } else if ([cmd[@"t"] isEqualToString:@"aux"]) {
                    // 辅助功能：与 AKUN 的 19940 动作一一对应，但走我们自己的控制通道
                    NSDictionary *res = [self.injector handleAux:cmd] ?: @{ @"success" : @NO };
                    NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithDictionary:res];
                    reply[@"t"] = @"auxResult";
                    reply[@"a"] = cmd[@"a"] ?: @"";
                    if (cmd[@"id"]) { reply[@"id"] = cmd[@"id"]; }
                    NSData *rd = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
                    NSString *rs = [[NSString alloc] initWithData:rd encoding:NSUTF8StringEncoding];
                    NSLog(@"[aux] %@ -> %@", cmd[@"a"], res[@"success"]);
                    [self.ctrlTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:rs]
                              completionHandler:^(NSError *e) {}];
                } else {
                    NSString *ct = cmd[@"t"];
                    if ([ct isEqualToString:@"tap"] || [ct isEqualToString:@"dtap"] ||
                        [ct isEqualToString:@"d"] || [ct isEqualToString:@"u"] ||
                        [ct isEqualToString:@"swipe"] || [ct isEqualToString:@"hk"] ||
                        ([ct isEqualToString:@"k"] && [cmd[@"code"] isEqualToString:@"home"])) {
                        [self kickBurstForInteraction];
                    }
                    [self.injector handleCommand:cmd];
                }
            }
        }
        [self receiveLoopOn:task];
    }];
}

- (void)scheduleReconnect {
    self.reconnectAttempt++;
    // 重连退避：0.5 → 1 → 2 → 4 → 5 秒封顶。
    // 原来是 2/4/8/16/30，服务端一重启手机要等十几秒才回来，
    // 用户看到的就是「首帧 7s / 16s」。网络抖一下也只掉半秒。
    double delay = MIN(0.5 * pow(2.0, (double)(self.reconnectAttempt - 1)), 5.0);
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


// root 侧 dpkg 数据助手：以 root 身份跑（launchd job com.akun.bridge.dpkgd），
// 监听回环 TCP，把 root 视图里的 dpkg status 原文吐给 daemon。
// 为什么不走文件共享：RootHide 下 daemon（注入进程）与 root ssh 的 /var/mobile
// 是两套视图，postinst 写的快照 daemon 一律看不到；回环 TCP 不受这个影响。
// root 侧执行助手：daemon 是注入进程（mobile），posix_spawn 起不来外部二进制（ENOENT），
// 所以 dpkg/unzip/uicache 这类必须由 uid=0 的 dpkgd 代跑。用 popen 走 /bin/sh。
__attribute__((unused)) static NSString *akun_sh_quote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

// jbroot 前缀：dpkgd 自身就在 .jbroot-XXXX 视图里，真机 dpkg/unzip/uicache 在 <jbroot>/usr/bin，
// 也可能在 /var/jb/usr/bin。PATH 一起给上，由 sh 自己找，不再靠绝对路径猜。
static NSString *akun_jb_prefix(void) {
    NSString *hm = NSHomeDirectory();
    NSRange r = [hm rangeOfString:@"/var/root" options:NSBackwardsSearch];
    if (r.location != NSNotFound && r.location > 1) return [hm substringToIndex:r.location];
    return @"";
}

// RootHide 下 dpkgd 里 popen()（= fork+/bin/sh）拿不到 shell，实测直接 rc=127 且无输出，
// 所以改成 posix_spawn + 管道：不依赖 sh，绝对路径直接 exec。
// dpkg 是 rootless 兼容二进制（libiosexec），会把 /var/mobile 自己映射进 jbroot；
// 而 dpkgd 是普通进程，看到的是真实 /var。约定 "@jb/<相对>"：落盘按 jbroot 展开，
// 传给 dpkg 时还原成 /<相对>，让 dpkg 自己去重定向。
static NSString *akun_expand_jb(NSString *p) {
    if ([p hasPrefix:@"@jb/"]) {
        return [[akun_jb_prefix() stringByAppendingString:@"/"] stringByAppendingString:[p substringFromIndex:4]];
    }
    return p;
}
static NSString *akun_strip_jb(NSString *p) {
    if ([p hasPrefix:@"@jb/"]) return [@"/" stringByAppendingString:[p substringFromIndex:4]];
    return p;
}

// ipa 解包后是 /Applications/Payload/<X>.app，多一层 Payload，SpringBoard 扫不到。
// 这里把 Payload 下的 *.app 搬到 /Applications 根，再删掉 Payload。
// ipa 解包后落在 /Applications/Payload/<X>.app，多一层 Payload，SpringBoard 扫不到。
// RootHide 下 unzip 写的是"真实" /Applications，而 dpkgd（注入进程）把它看成
// <jbroot>/Applications —— 实测 opendir("/Applications/Payload") MISS，
// opendir("<jbroot>/Applications/Payload") OK，所以这里统一用 jbroot 前缀定位。
static void akun_fix_tipa_layout(void) {
    NSString *jbp = akun_jb_prefix();
    char pay[640], appdir[640], src[768], dst[768];
    snprintf(pay, sizeof(pay), "%s/Applications/Payload", jbp.UTF8String);
    snprintf(appdir, sizeof(appdir), "%s/Applications", jbp.UTF8String);

    DIR *d = opendir(pay);
    if (!d) {
        printf("[tipa] payload 目录不存在: %s\n", pay);
        fflush(stdout);
        return;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        size_t n = strlen(e->d_name);
        if (n < 4 || strcmp(e->d_name + n - 4, ".app") != 0) continue;
        snprintf(src, sizeof(src), "%s/%s", pay, e->d_name);
        snprintf(dst, sizeof(dst), "%s/%s", appdir, e->d_name);
        if (rename(src, dst) == 0) printf("[tipa] moved -> %s\n", dst);
        else printf("[tipa] rename fail %s errno=%d\n", src, errno);
    }
    closedir(d);
    rmdir(pay);
    printf("[tipa] done\n");
    fflush(stdout);
}

static NSString *akun_which(NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pfx = akun_jb_prefix();
    for (NSString *c in @[ [NSString stringWithFormat:@"%@/usr/bin/%@", pfx, name],
                            [NSString stringWithFormat:@"%@/var/jb/usr/bin/%@", pfx, name],
                            [NSString stringWithFormat:@"/var/jb/usr/bin/%@", name],
                            [NSString stringWithFormat:@"/usr/bin/%@", name],
                            [NSString stringWithFormat:@"/usr/sbin/%@", name],
                            [NSString stringWithFormat:@"/bin/%@", name] ]) {
        if ([fm fileExistsAtPath:c]) return c;
        if (access(c.UTF8String, X_OK) == 0) return c;
    }
    return nil;
}

static int akun_root_exec(NSArray *argv, NSString **outStr) {
    if (!argv.count) { *outStr = @"empty argv"; return -1; }
    NSString *bin = akun_which(argv.firstObject);
    if (!bin) { *outStr = [NSString stringWithFormat:@"找不到可执行文件: %@", argv.firstObject]; return -127; }

    NSMutableArray *cstrs = [NSMutableArray array];
    for (NSString *a in argv) {
        const char *c = a.UTF8String;
        [cstrs addObject:[NSData dataWithBytes:c length:strlen(c) + 1]];
    }
    char **args = (char **)calloc(cstrs.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < cstrs.count; i++) {
        args[i] = (char *)[cstrs[i] bytes];
    }
    args[cstrs.count] = NULL;

    int pfd[2] = { -1, -1 };
    if (pipe(pfd) != 0) { free(args); *outStr = @"pipe 失败"; return -1; }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    posix_spawn_file_actions_addclose(&fa, pfd[1]);

    pid_t pid = 0;
    int prc = posix_spawn(&pid, bin.UTF8String, &fa, NULL, args, environ);
    posix_spawn_file_actions_destroy(&fa);
    free(args);
    close(pfd[1]);
    if (prc != 0) {
        close(pfd[0]);
        *outStr = [NSString stringWithFormat:@"posix_spawn 失败 %@ : errno=%d", bin, prc];
        NSLog(@"[dpkgd] posix_spawn %@ 失败 %d", bin, prc);
        return -1;
    }
    NSMutableData *buf = [NSMutableData data];
    char b[4096];
    ssize_t n = 0;
    while ((n = read(pfd[0], b, sizeof(b))) > 0) {
        [buf appendBytes:b length:n];
        if (buf.length > 262144) break;
    }
    close(pfd[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    int rc = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    NSString *o = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
    if (!o.length) o = [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
    *outStr = o ?: @"";
    NSLog(@"[dpkgd] spawn %@ rc=%d", bin, rc);
    return rc;
}

__attribute__((unused)) static NSString *akun_pick_bin(NSArray *cands) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in cands) { if ([fm fileExistsAtPath:c]) return c; }
    return cands.lastObject;
}

static void akun_run_dpkgd(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { NSLog(@"[dpkgd] socket 失败"); return; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        NSLog(@"[dpkgd] bind 失败 errno=%d", errno);
        return;
    }
    if (listen(fd, 8) != 0) { NSLog(@"[dpkgd] listen 失败"); return; }
    NSLog(@"[dpkgd] 监听 127.0.0.1:%d uid=%d", port, getuid());
    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) { continue; }
        // 首行读必须有超时：客户端可能（像原来的 LIST）不带换行直接发一段就等回包，
        // 没有超时这里会把单线程 accept 循环永久堵死。
        struct timeval rtv; rtv.tv_sec = 2; rtv.tv_usec = 0;
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));
        // 首行协议：Open字节流读首行（\n 分隔）。PUTA 还要继续读固定长度的 base64 正文，
        // 因为 RootHide 下注入进程与 root/dpkg 的文件视图不共享，包必须由 dpkgd 自己落盘。
        NSMutableData *acc = [NSMutableData data];
        NSString *firstLine = nil;
        NSUInteger bodyStart = 0;
        char rb0[4096];
        while (!firstLine) {
            ssize_t n = read(c, rb0, sizeof(rb0));
            if (n <= 0) break;
            [acc appendData:[NSData dataWithBytes:rb0 length:(NSUInteger)n]];
            NSRange nl = [acc rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                   options:0 range:NSMakeRange(0, acc.length)];
            if (nl.location != NSNotFound) {
                NSData *hd = [acc subdataWithRange:NSMakeRange(0, nl.location)];
                firstLine = [[NSString alloc] initWithData:hd encoding:NSUTF8StringEncoding] ?: @"";
                bodyStart = nl.location + 1;
            } else if (acc.length > 65536) {
                break;
            }
        }
        if (!firstLine) { firstLine = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding] ?: @""; bodyStart = acc.length; }
        NSString *reqStr = [firstLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![reqStr isEqualToString:@"LIST"] && reqStr.length) {
            // 写库类动作统一走这里：DPKG_I <path> / DPKG_R <pkg> / TIPAQ <path>
            NSArray *parts = [reqStr componentsSeparatedByString:@" "];
            NSString *verb = parts.firstObject ?: @"";
            NSString *arg = ([parts count] > 1) ? [reqStr substringFromIndex:verb.length + 1] : @"";
            NSString *outp = @"";
            int rc = -1;
            NSFileManager *fm = [NSFileManager defaultManager];

            if ([verb isEqualToString:@"PUTA"]) {
                // arg: "<path> <offset> <b64len>"
                NSArray *ap = [arg componentsSeparatedByString:@" "];
                if (ap.count < 3) { outp = @"PUTA 参数不足"; rc = -2; }
                else {
                    NSString *dp = akun_expand_jb(ap[0]);
                    long long off = [ap[1] longLongValue];
                    NSUInteger want = (NSUInteger)[ap[2] longLongValue];
                    NSMutableData *body = [NSMutableData data];
                    NSUInteger have = acc.length > bodyStart ? acc.length - bodyStart : 0;
                    if (have) [body appendData:[acc subdataWithRange:NSMakeRange(bodyStart, have)]];
                    char rb1[8192];
                    while (body.length < want) {
                        ssize_t n = read(c, rb1, sizeof(rb1));
                        if (n <= 0) break;
                        [body appendBytes:rb1 length:(NSUInteger)n];
                    }
                    if (body.length < want) {
                        outp = [NSString stringWithFormat:@"正文不足 %lu/%lu", (unsigned long)body.length, (unsigned long)want];
                        rc = -3;
                    } else {
                        NSData *raw = [[NSData alloc] initWithBase64EncodedData:body options:0];
                        if (!raw.length) { outp = @"base64 解码为空"; rc = -4; }
                        else {
                            FILE *fp = (off == 0) ? fopen(dp.UTF8String, "wb") : fopen(dp.UTF8String, "r+b");
                            if (!fp) {
                                outp = [NSString stringWithFormat:@"fopen 失败 errno=%d path=%@", errno, dp];
                                rc = -5;
                            } else {
                                if (off != 0) fseek(fp, (long)off, SEEK_SET);
                                size_t wr = fwrite(raw.bytes, 1, raw.length, fp);
                                fclose(fp);
                                chmod(dp.UTF8String, 0644);
                                outp = [NSString stringWithFormat:@"written=%zu off=%lld total=%lld path=%@",
                                        wr, off, off + (long long)raw.length, dp];
                                rc = (wr == raw.length) ? 0 : -6;
                            }
                        }
                    }
                }
            } else if ([verb isEqualToString:@"DPKG_I"] && arg.length) {
                NSString *real = akun_expand_jb(arg);
                if (![fm fileExistsAtPath:real]) { rc = -9; outp = [NSString stringWithFormat:@"文件不存在: %@ (展开 %@)", arg, real]; }
                else {
                    rc = akun_root_exec(@[ @"dpkg", @"-i", akun_strip_jb(arg) ], &outp);
                }
            } else if ([verb isEqualToString:@"DPKG_R"] && arg.length) {
                rc = akun_root_exec(@[ @"dpkg", @"-r", arg ], &outp);
            } else if ([verb isEqualToString:@"DELE"] && arg.length) {
                // 装完清包：root 侧删，避免 mobile 无权删 root 属主的旧包
                NSString *real = akun_expand_jb(arg);
                if (unlink(real.UTF8String) == 0) { rc = 0; outp = [NSString stringWithFormat:@"deleted %@", real]; }
                else { rc = errno == ENOENT ? 0 : -1; outp = [NSString stringWithFormat:@"unlink errno=%d %@", errno, real]; }
            } else if ([verb isEqualToString:@"KILLSB"]) {
                // respring：root 侧用 sysctl 遍历进程表，按 p_comm 找 SpringBoard 再 SIGKILL。
                int killed = 0, scanned = 0;
                int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
                size_t len = 0;
                if (sysctl(mib, 4, NULL, &len, NULL, 0) == 0 && len > 0) {
                    struct kinfo_proc *kp = (struct kinfo_proc *)malloc(len);
                    if (kp && sysctl(mib, 4, kp, &len, NULL, 0) == 0) {
                        int n = (int)(len / sizeof(struct kinfo_proc));
                        for (int i = 0; i < n; i++) {
                            pid_t pid = kp[i].kp_proc.p_pid;
                            if (pid <= 1) continue;
                            scanned++;
                            const char *comm = kp[i].kp_proc.p_comm;
                            if (comm && strstr(comm, "SpringBoard")) {
                                if (kill(pid, SIGKILL) == 0) killed++;
                            }
                        }
                    }
                    if (kp) free(kp);
                }
                rc = killed > 0 ? 0 : 1;
                outp = [NSString stringWithFormat:@"killed=%d scanned=%d", killed, scanned];
            } else if ([verb isEqualToString:@"ASSIST_ON"] || [verb isEqualToString:@"ASSIST_OFF"]) {
                // 逐字照抄 AKUN rootd（trollvncserver.mm:6415-6483）：
                //   开：bootstrap user/foreground <rootfs plist>（不看返回码）→ kickstart -kp user/501
                //       → 只有 rc≠0 才补 kickstart -kp user/foreground
                //   关：bootout system/com.apple.assistivetouchd，再由主进程 SIGTERM 那个进程
                // 一条不多一条不少，别自己加域循环、别加 Accessib ilityUIServer 兜底。
                BOOL wantOn = [verb isEqualToString:@"ASSIST_ON"];
                NSString *plist = @"/rootfs/System/Library/LaunchDaemons/com.apple.assistivetouchd.plist";
                NSString *o1 = @"", *o2 = @"", *o3 = @"", *o4 = @"";
                if (wantOn) {
                    int b  = akun_root_exec(@[ @"launchctl", @"bootstrap", @"user/foreground", plist ], &o1);
                    int k1 = akun_root_exec(@[ @"launchctl", @"kickstart", @"-kp",
                                               @"user/501/com.apple.assistivetouchd" ], &o2);
                    rc = k1;
                    int k2 = -1;
                    if (rc != 0) {
                        k2 = akun_root_exec(@[ @"launchctl", @"kickstart", @"-kp",
                                               @"user/foreground/com.apple.assistivetouchd" ], &o3);
                        rc = k2;
                    }
                    outp = [NSString stringWithFormat:@"bootstrap=%d(plist %s) kick501=%d kickfg=%d [%@][%@]",
                            b, [fm fileExistsAtPath:plist] ? "存在" : "不存在", k1, k2,
                            o2.length ? o2 : @"", o3.length ? o3 : @""];
                } else {
                    rc = akun_root_exec(@[ @"launchctl", @"bootout", @"system/com.apple.assistivetouchd" ], &o1);
                    int sig = akun_root_exec(@[ @"killall", @"-TERM", @"assistivetouchd" ], &o4);
                    outp = [NSString stringWithFormat:@"bootout=%d killall=%d [%@][%@]",
                            rc, sig, o1.length ? o1 : @"", o4.length ? o4 : @""];
                }
            } else if ([verb isEqualToString:@"TIPAQ"] && arg.length) {
                NSString *real = akun_expand_jb(arg);
                if (![fm fileExistsAtPath:real]) { rc = -9; outp = [NSString stringWithFormat:@"文件不存在: %@ (展开 %@)", arg, real]; }
                else {
                    rc = akun_root_exec(@[ @"unzip", @"-o", akun_strip_jb(arg), @"-d", @"/Applications" ], &outp);
                    if (rc == 0) {
                        akun_fix_tipa_layout();
                        NSString *o2 = @""; akun_root_exec(@[ @"uicache", @"-a" ], &o2);
                        outp = [outp stringByAppendingString:o2];
                    }
                }
            } else {
                outp = [NSString stringWithFormat:@"未知指令: %@", reqStr];
                rc = -1;
            }
            NSLog(@"[dpkgd] %@ rc=%d", verb, rc);
            if (rc == 127) {
                outp = [NSString stringWithFormat:@"[PATH 里没有该命令 prefix=%@] %@", akun_jb_prefix(), (outp ?: @"")];
            }
            NSString *resp = [NSString stringWithFormat:@"OK %d\n%@", rc, (outp ?: @"")];
            NSData *rd = [resp dataUsingEncoding:NSUTF8StringEncoding];
            const char *rb = (const char *)rd.bytes;
            NSUInteger rl = rd.length;
            while (rl > 0) {
                ssize_t w = write(c, rb, rl);
                if (w <= 0) break;
                rb += w; rl -= (NSUInteger)w;
            }
            close(c);
            continue;
        }
        NSData *out = nil;
        NSMutableString *diag = [NSMutableString string];
        // RootHide/roothide：/var/lib/dpkg 是指向 .jbroot/Library/dpkg 的相对软链，
        // 注入进程的 /var 已被重定向到 .jbroot-*/var（里面没有 dpkg），真实数据库在 /Library/dpkg/status。
        NSMutableArray *cands = [NSMutableArray arrayWithObjects:
            @"/Library/dpkg/status",
            @"/var/jb/Library/dpkg/status",
            @"/var/jb/var/lib/dpkg/status",
            @"/var/lib/dpkg/status",
            @"/var/lib/dpkg/status-old", nil];
        NSString *hm = NSHomeDirectory();
        NSRange rr = [hm rangeOfString:@"/var/root" options:NSBackwardsSearch];
        if (rr.location != NSNotFound && rr.location > 1) {
            NSString *prefix = [hm substringToIndex:rr.location];   // .../.jbroot-XXXXXXXX
            [cands insertObject:[prefix stringByAppendingString:@"/Library/dpkg/status"] atIndex:0];
        }
        for (NSString *p in cands) {
            FILE *f = fopen(p.UTF8String, "rb");
            if (!f) {
                [diag appendFormat:@"miss %@ errno=%d\n", p, errno];
                continue;
            }
            NSMutableData *d = [NSMutableData data];
            char b[8192];
            size_t n = 0;
            while ((n = fread(b, 1, sizeof(b), f)) > 0) { [d appendBytes:b length:n]; }
            fclose(f);
            [diag appendFormat:@"read %@ %lu\n", p, (unsigned long)d.length];
            if (d.length > 100) { out = d; break; }
        }
        [diag appendFormat:@"uid=%d home=%@\n", getuid(), NSHomeDirectory()];
        NSLog(@"[dpkgd] %@", diag);
        NSMutableData *all = [NSMutableData data];
        NSString *head = [NSString stringWithFormat:@"DIAG:\n%@---STATUS---\n", diag];
        [all appendData:[head dataUsingEncoding:NSUTF8StringEncoding]];
        if (out.length) { [all appendData:out]; NSLog(@"[dpkgd] 提供 %lu B", (unsigned long)out.length); }
        const char *bytes = (const char *)all.bytes;
        NSUInteger left = all.length;
        while (left > 0) {
            ssize_t w = write(c, bytes, left);
            if (w <= 0) break;
            bytes += w;
            left -= (NSUInteger)w;
        }
        close(c);
    }
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
        if (argc >= 2 && strcmp(argv[1], "--dpkgd") == 0) {
            int port = (argc > 2) ? atoi(argv[2]) : 19949;
            akun_run_dpkgd(port);
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
