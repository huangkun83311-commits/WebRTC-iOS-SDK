//  AkunBridge daemon — 手机侧常驻进程
//
//  与 IPA 那套（ReplayKit 扩展 + App）的差别：
//    1. 它是 /usr/bin 下的独立进程，由 LaunchDaemon 以 mobile 用户常驻拉起；
//    2. 抓屏走 IOMobileFramebuffer/IOSurface，不需要用户手动开「屏幕录制」；
//    3. 能注入 HID 事件（依赖 entitlements 里的 hid.client.event-dispatch），
//       所以电脑端点击、滑动、回桌面都能作用到整个系统，而不只是自己这个 App。

#import <Foundation/Foundation.h>
#import "AkunCapture.h"
#import "AkunInjector.h"
#import "AkunRTC.h"

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
    NSLog(@"[daemon] 没读到任何配置文件，检查 com.akun.bridge.plist");
    return @{};
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

- (void)start {
    NSDictionary *prefs = [self loadPrefs];
    self.serverBase = prefs[@"ServerBase"] ?: @"";
    self.deviceId = prefs[@"DeviceId"] ?: @"dev001";
    NSLog(@"[daemon] server=%@ device=%@", self.serverBase, self.deviceId);

    self.injector = [[AkunInjector alloc] init];
    self.capture = [[AkunCapture alloc] init];

    __weak typeof(self) weakSelf = self;
    self.capture.frameHandler = ^(CVPixelBufferRef pixelBuffer) {
        weakSelf.frameCount++;
        if (weakSelf.frameCount % 60 == 0) {
            NSLog(@"[daemon] frames=%llu %zux%zu", weakSelf.frameCount,
                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
        }
        [weakSelf.rtc pushPixelBuffer:pixelBuffer];
    };

    self.rtc = [[AkunRTC alloc] initWithServerBase:self.serverBase deviceId:self.deviceId];
    [self.rtc start];

    if (![self.capture start]) {
        NSLog(@"[daemon] 抓屏启动失败");
    }
    [self connectCtrl];
}

#pragma mark - 控制通道

- (void)connectCtrl {
    NSString *urlString = [self ctrlURLString];
    NSLog(@"[daemon] 连接控制通道 %@", urlString);
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { return; }

    if (!self.session) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }

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
        [self.ctrlTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        [self connectCtrl];
    });
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