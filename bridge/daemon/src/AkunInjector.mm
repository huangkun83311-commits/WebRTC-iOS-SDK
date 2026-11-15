#import "AkunInjector.h"

#import <CoreGraphics/CGGeometry.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>

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
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateSimpleClient(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

// 不同 iOS 版本的 phase 位定义不同：常见 {1,2,4} 或 {1,2,3}。
// 若注入无反应，只换这三行即可，不用动逻辑。
#define HID_PHASE_BEGAN 1
#define HID_PHASE_MOVED 2
#define HID_PHASE_ENDED 4

#define HID_TYPE_HAND 3
static const double kMinEventInterval = 0.012;

@implementation AkunInjector {
    IOHIDEventSystemClientRef _client;
    NSTimeInterval _lastDispatch;
}

- (instancetype)init {
    if ((self = [super init])) {
        _client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
        NSLog(@"[inject] client=%p", _client);
    }
    return self;
}

- (void)dispatchPhase:(uint32_t)phase x:(double)x y:(double)y {
    if (!_client) { return; }

    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastDispatch < kMinEventInterval && phase == HID_PHASE_MOVED) { return; }
    _lastDispatch = now;

    uint64_t ts = mach_absolute_time();
    BOOL touching = (phase != HID_PHASE_ENDED);

    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, HID_TYPE_HAND,
        0, 1, phase, 0,
        x, y, 0,
        0, 0, 0, 0, 0,
        0, touching);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        0, 2, phase,
        x, y, 0, 0, 0,
        0, touching);

    if (hand && finger) {
        IOHIDEventAppendEvent(hand, finger, 0);
        // 让系统认为事件来自内置触摸屏的修饰位，字段号跨版本不一致，默认不开。
        // IOHIDEventSetIntegerValue(hand, 0x00030000, 1);
        // IOHIDEventSetIntegerValue(hand, 0x00030001, 1);
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
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
    } else if ([t isEqualToString:@"m"]) {
        [self dispatchPhase:HID_PHASE_MOVED x:x y:y];
    } else if ([t isEqualToString:@"u"]) {
        [self dispatchPhase:HID_PHASE_ENDED x:x y:y];
    } else if ([t isEqualToString:@"tap"]) {
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
        usleep(30000);
        [self dispatchPhase:HID_PHASE_ENDED x:x y:y];
    } else if ([t isEqualToString:@"swipe"]) {
        double x2 = [cmd[@"x2"] doubleValue];
        double y2 = [cmd[@"y2"] doubleValue];
        int steps = 12;
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
        for (int i = 1; i <= steps; i++) {
            double k = (double)i / steps;
            [self dispatchPhase:HID_PHASE_MOVED x:x + (x2 - x) * k y:y + (y2 - y) * k];
            usleep(12000);
        }
        [self dispatchPhase:HID_PHASE_ENDED x:x2 y:y2];
    } else if ([t isEqualToString:@"k"]) {
        NSString *code = cmd[@"code"];
        NSLog(@"[inject] key %@", code);
        [self dispatchKey:code];
    }
}

/// Home / 锁屏这类硬按键：走 HID 键盘事件不通用，这里先用私有服务兜底。
- (void)dispatchKey:(NSString *)code {
    if ([code isEqualToString:@"home"]) {
        // SpringBoard 的 home 手势：从屏幕下缘外往上滑一段即可回桌面。
        [self dispatchPhase:HID_PHASE_BEGAN x:0.5 y:0.995];
        [self dispatchPhase:HID_PHASE_MOVED x:0.5 y:0.85];
        [self dispatchPhase:HID_PHASE_ENDED x:0.5 y:0.75];
    }
}

@end