//
//  AkunBridge Tweak — 注入 SpringBoard，接控制指令并用 IOHIDEvent 合成触摸
//
//  为什么注入 SpringBoard 而不是做成 App：
//    iOS 沙盒禁止 App 向别的 App 注入触摸；SpringBoard 进程本身就持有 HID 派发权限，
//    在它的上下文里调 IOHIDEventSystemClientDispatchEvent 才能真的点到桌面/其它 App。
//
//  编译：Theos（rootless），见同目录 Makefile
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ======================= 私有 API 声明 =======================

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timestamp, int transducerType,
    uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
    double x, double y, double z, double tipPressure, double barrelPressure,
    double tiltX, double tiltY, double twist, Boolean range, Boolean touch);

extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator, uint64_t timestamp, uint32_t index, uint32_t identity,
    uint32_t eventMask, double x, double y, double z, double tipPressure,
    double twist, Boolean range, Boolean touch);

extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t option);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, int32_t field, int64_t value);
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, int32_t field, double value);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateSimpleClient(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

// ======================= 需要真机校准的常量 =======================
// 如果注入完全没反应，优先调这里。不同 iOS 版本 IOHIDEventPhase 的位定义略有差异：
//   常见一：Began=1, Moved=2, Ended=4
//   常见二：Began=1, Moved=2, Ended=3
// 先用下面这组；不通就整组换成第二组再试。
#define HID_PHASE_BEGAN 1
#define HID_PHASE_MOVED 2
#define HID_PHASE_ENDED 4

// kIOHIDDigitizerTransducerTypeHand
#define HID_TYPE_HAND 3

// 坐标单位：1 = 传归一化坐标(0~1)，0 = 传屏幕像素坐标
#define USE_NORMALIZED_COORDS 1

// 指令间最小间隔，防止 SpringBoard 被高频事件打爆
static const double kMinEventInterval = 0.012;

// ======================= 注入实现 =======================

@interface AkunInjector : NSObject
+ (instancetype)shared;
- (void)handleCommand:(NSDictionary *)cmd;
@end

@implementation AkunInjector {
    IOHIDEventSystemClientRef _client;
    NSTimeInterval _lastDispatch;
}

+ (instancetype)shared {
    static AkunInjector *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[AkunInjector alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    }
    return self;
}

/// 把归一化坐标换成注入用的坐标
- (CGPoint)pointFromNormalized:(double)x y:(double)y {
#if USE_NORMALIZED_COORDS
    return CGPointMake(x, y);
#else
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) { keyWindow = [UIApplication sharedApplication].windows.firstObject; }
    CGRect bounds = keyWindow.bounds;
    CGFloat scale = keyWindow.screen.scale ?: 3.0;
    return CGPointMake(x * CGRectGetWidth(bounds) * scale, y * CGRectGetHeight(bounds) * scale);
#endif
}

- (void)dispatchPhase:(uint32_t)phase x:(double)x y:(double)y {
    if (!_client) { return; }

    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastDispatch < kMinEventInterval && phase == HID_PHASE_MOVED) { return; }
    _lastDispatch = now;

    CGPoint p = [self pointFromNormalized:x y:y];
    uint64_t ts = mach_absolute_time();

    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, HID_TYPE_HAND,
        0, 1,
        phase, 0,
        p.x, p.y, 0,
        0, 0, 0, 0, 0,
        0, (phase != HID_PHASE_ENDED));

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        0, 2, phase,
        p.x, p.y, 0, 0, 0,
        0, (phase != HID_PHASE_ENDED));

    if (hand && finger) {
        IOHIDEventAppendEvent(hand, finger, 0);
        // 下面两行是「让 SpringBoard 认为这条事件来自内置触摸屏」的修饰字段。
        // 不同 iOS 版本的字段号不一样，默认关闭；注入完全没反应时依次打开试。
        // IOHIDEventSetIntegerValue(hand, 0x00030000 /* IsBuiltIn */, 1);
        // IOHIDEventSetIntegerValue(hand, 0x00030001 /* IsDisplayIntegrated */, 1);
        IOHIDEventSetSenderID(hand, 0x8000000817319372ULL);
        IOHIDEventSystemClientDispatchEvent(_client, hand);
    }

    if (finger) { CFRelease(finger); }
    if (hand) { CFRelease(hand); }
}

- (void)handleCommand:(NSDictionary *)cmd {
    NSString *t = cmd[@"t"];
    if (![t isKindOfClass:[NSString class]]) { return; }

    double x = [cmd[@"x"] doubleValue];
    double y = [cmd[@"y"] doubleValue];

    if ([t isEqualToString:@"d"]) {
        NSLog(@"[AkunBridge] down %.3f,%.3f", x, y);
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
    } else if ([t isEqualToString:@"m"]) {
        [self dispatchPhase:HID_PHASE_MOVED x:x y:y];
    } else if ([t isEqualToString:@"u"]) {
        NSLog(@"[AkunBridge] up %.3f,%.3f", x, y);
        [self dispatchPhase:HID_PHASE_ENDED x:x y:y];
    } else if ([t isEqualToString:@"tap"]) {
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self dispatchPhase:HID_PHASE_ENDED x:x y:y];
        });
    } else if ([t isEqualToString:@"lp"]) {
        // 长按：按下 → 900ms → 抬起
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self dispatchPhase:HID_PHASE_ENDED x:x y:y];
        });
    } else if ([t isEqualToString:@"swipe"]) {
        [self runSwipeFrom:CGPointMake([cmd[@"x1"] doubleValue], [cmd[@"y1"] doubleValue])
                          to:CGPointMake([cmd[@"x2"] doubleValue], [cmd[@"y2"] doubleValue])
                   duration:[cmd[@"ms"] doubleValue] / 1000.0];
    } else if ([t isEqualToString:@"k"]) {
        // TODO: Home / 音量需要另接 SpringBoard 私有接口，触摸链路稳定后再补。
        NSLog(@"[AkunBridge] key not implemented: %@", cmd[@"code"]);
    }
}

- (void)runSwipeFrom:(CGPoint)from to:(CGPoint)to duration:(double)duration {
    if (duration <= 0) { duration = 0.3; }
    int steps = MAX(6, (int)(duration * 60));
    [self dispatchPhase:HID_PHASE_BEGAN x:from.x y:from.y];

    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        double x = from.x + (to.x - from.x) * t;
        double y = from.y + (to.y - from.y) * t;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration / steps * i) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self dispatchPhase:HID_PHASE_MOVED x:x y:y];
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 0.02) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self dispatchPhase:HID_PHASE_ENDED x:to.x y:to.y];
    });
}

@end

// ======================= WebSocket 客户端 =======================

@interface AkunBridgeClient : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) NSURLSessionWebSocketTask *task;
@property (nonatomic, copy) NSString *serverBase;
@property (nonatomic, copy) NSString *deviceId;
@property (nonatomic, assign) NSInteger retry;
@end

@implementation AkunBridgeClient

+ (instancetype)shared {
    static AkunBridgeClient *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[AkunBridgeClient alloc] init]; });
    return inst;
}

/// 配置来源：/var/jb/var/mobile/Library/Preferences/com.akun.bridge.plist
/// 键：ServerBase（ws://1.2.3.4:8080）、DeviceId
- (void)loadConfig {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/jb/var/mobile/Library/Preferences/com.akun.bridge.plist"];
    if (!cfg) {
        cfg = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.akun.bridge.plist"];
    }
    self.serverBase = cfg[@"ServerBase"] ?: @"ws://127.0.0.1:8080";
    self.deviceId = cfg[@"DeviceId"] ?: @"dev001";
}

- (void)start {
    [self loadConfig];

    NSString *base = self.serverBase;
    while ([base hasSuffix:@"/"]) { base = [base substringToIndex:base.length - 1]; }

    NSString *urlStr = [NSString stringWithFormat:@"%@/ws?room=ctrl-%@&role=phone", base, self.deviceId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        NSLog(@"[AkunBridge] 非法信令地址: %@", urlStr);
        return;
    }

    NSURLSession *session = [NSURLSession sessionWithConfiguration:
        [NSURLSessionConfiguration defaultSessionConfiguration]
        delegate:self delegateQueue:[NSOperationQueue mainQueue]];

    self.task = [session webSocketTaskWithURL:url];
    [self.task resume];

    NSLog(@"[AkunBridge] connecting %@", urlStr);
    [self receive];
    [self ping];
}

- (void)reconnect {
    self.retry += 1;
    double delay = MIN(pow(2.0, (double)self.retry), 30.0);
    NSLog(@"[AkunBridge] reconnect in %.1fs (attempt %ld)", delay, (long)self.retry);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self start]; });
}

- (void)receive {
    __weak typeof(self) weakSelf = self;
    [self.task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }

        if (error) {
            NSLog(@"[AkunBridge] ws error: %@", error.localizedDescription);
            [self reconnect];
            return;
        }

        if (message.type == NSURLSessionWebSocketMessageTypeString && message.string) {
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                [[AkunInjector shared] handleCommand:obj];
            }
        }

        [self receive];
    }];
}

- (void)ping {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self.task) { return; }
        [self.task sendPingWithPongReceiveHandler:^(NSError *error) {
            if (error) {
                NSLog(@"[AkunBridge] ping failed: %@", error.localizedDescription);
                [self reconnect];
            } else {
                self.retry = 0;
                [self ping];
            }
        }];
    });
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(NSString *)protocol {
    NSLog(@"[AkunBridge] connected, protocol=%@", protocol);
    self.retry = 0;
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
           reason:(NSData *)reason {
    NSLog(@"[AkunBridge] closed code=%ld", (long)closeCode);
    [self reconnect];
}

@end

// ======================= 入口 =======================

%ctor {
    // 等 SpringBoard 起来再连，太早会拿不到 UIWindow / HID 客户端
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSLog(@"[AkunBridge] booting controller");
        [[AkunBridgeClient shared] start];
    });
}
