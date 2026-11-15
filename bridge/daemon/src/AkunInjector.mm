//  AkunInjector — 触摸事件注入
//
//  与 AKUN（TrollVNC 的 STHIDEventGenerator）同一套私有 API，但全部走 dlsym：
//
//  为什么不能直接 extern 声明：
//    链接时用 -Wl,-undefined,dynamic_lookup，缺的符号会变成「陷阱桩」，
//    一旦调用就 dyld: missing symbol called 直接崩，而且不给符号名。
//    iOS 16 上 IOHIDEventSystemClientCreateSimpleClient 就已经不存在了，
//    直接调用必然是这条路 —— 真机上表现为启动日志打完配置行就死。
//
//  正确的取法是 IOHIDEventSystemClientCreate（AKUN 用的就是它），依次回退。

#import "AkunInjector.h"

#import <CoreGraphics/CGGeometry.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

typedef IOHIDEventRef (*CreateDigitizerEventFn)(CFAllocatorRef, uint64_t, int, uint32_t, uint32_t,
                                                uint32_t, uint32_t, double, double, double, double,
                                                double, double, double, double, Boolean, Boolean);
typedef IOHIDEventRef (*CreateFingerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                             uint32_t, double, double, double, double, double,
                                             Boolean, Boolean);
typedef void (*AppendEventFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*SetIntegerValueFn)(IOHIDEventRef, int32_t, int64_t);
typedef void (*SetFloatValueFn)(IOHIDEventRef, int32_t, double);
typedef void (*SetSenderIDFn)(IOHIDEventRef, uint64_t);
typedef IOHIDEventSystemClientRef (*ClientCreateFn)(CFAllocatorRef);
typedef IOHIDEventSystemClientRef (*ClientCreateWithTypeFn)(CFAllocatorRef, int, void *);
typedef void (*DispatchEventFn)(IOHIDEventSystemClientRef, IOHIDEventRef);

// IOHIDEventField 数值（对照 AKUN include-spi/IOKitSPI.h 的枚举）
#define kHIDFieldIsBuiltIn 4                                  // kIOHIDEventTypeNULL 基址 + 4
#define kHIDFieldDigitizerIsDisplayIntegrated 0x00030019      // 基址 0x30000 + 20 + 5
#define kHIDFieldDigitizerMajorRadius 0x00030014              // 基址 0x30000 + 20
#define kHIDFieldDigitizerMinorRadius 0x00030015

#define HID_PHASE_BEGAN 1
#define HID_PHASE_MOVED 2
#define HID_PHASE_ENDED 4

// IOHIDDigitizerEventMask（照 IOKitSPI.h 的位定义：Identity=1<<5、Attribute=1<<6）
#define HID_MASK_RANGE     0x00000001
#define HID_MASK_TOUCH     0x00000002
#define HID_MASK_POSITION  0x00000004
#define HID_MASK_IDENTITY  0x00000020
#define HID_MASK_ATTRIBUTE 0x00000040

#define HID_FINGER_ID 2   // AKUN 的 fingerIdentifiers[0]

#define HID_TYPE_HAND 3
#define HID_TYPE_FINGER 2

// AKUN 用的发送者 ID；内置触摸屏修饰位不一致时它是关键一项
static const uint64_t kSenderID = 0x8000000817319371ULL;
static const double kMinEventInterval = 0.012;

@implementation AkunInjector {
    IOHIDEventSystemClientRef _client;
    NSTimeInterval _lastDispatch;

    CreateDigitizerEventFn _createHand;
    CreateFingerEventFn _createFinger;
    AppendEventFn _appendEvent;
    SetIntegerValueFn _setInteger;
    SetFloatValueFn _setFloat;
    SetSenderIDFn _setSenderID;
    DispatchEventFn _dispatch;
}

- (instancetype)init {
    if ((self = [super init])) {
        _createHand = (CreateDigitizerEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        _createFinger = (CreateFingerEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        _appendEvent = (AppendEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        _setInteger = (SetIntegerValueFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        _setFloat = (SetFloatValueFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
        _setSenderID = (SetSenderIDFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        _dispatch = (DispatchEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");

        ClientCreateFn simpleFn =
            (ClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateSimpleClient");
        ClientCreateFn createFn = (ClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        ClientCreateWithTypeFn createWithType =
            (ClientCreateWithTypeFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");

        if (createFn) {
            _client = createFn(kCFAllocatorDefault);
        } else if (simpleFn) {
            _client = simpleFn(kCFAllocatorDefault);
        } else if (createWithType) {
            _client = createWithType(kCFAllocatorDefault, 3, NULL);   // 3 = digitizer
        }

        NSLog(@"[inject] client=%p (create=%p simple=%p withType=%p) symbols hand=%p finger=%p "
              @"append=%p dispatch=%p senderID=%p",
              _client, createFn, simpleFn, createWithType,
              _createHand, _createFinger, _appendEvent, _dispatch, _setSenderID);

        if (!_client || !_createHand || !_createFinger || !_appendEvent || !_dispatch) {
            NSLog(@"[inject] 私有符号不全，注入功能不可用（看上面指针哪个是 0）");
        }
    }
    return self;
}

/// 注入 API 的 x/y 是「0~1 归一化」坐标（AKUN 里也是先把点坐标除以屏幕像素再喂进去），
/// 所以要拿的是屏幕像素尺寸只用于日志，真正喂给 HID 的必须是 0~1。
- (CGSize)screenPointSize {
    @try {
        CGSize s = [UIScreen mainScreen].bounds.size;
        if (s.width > 1 && s.height > 1) { return s; }
    } @catch (NSException *e) {
    }
    return CGSizeMake(414, 736);
}

static double clamp01(double v) {
    if (v < 0) { return 0; }
    if (v > 1) { return 1; }
    return v;
}

- (void)dispatchPhase:(uint32_t)phase x:(double)x y:(double)y {
    if (!_client || !_createHand || !_createFinger || !_appendEvent || !_dispatch) { return; }

    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastDispatch < kMinEventInterval && phase == HID_PHASE_MOVED) { return; }
    _lastDispatch = now;

    uint64_t ts = mach_absolute_time();
    Boolean touching = (phase != HID_PHASE_ENDED);

    // 掩码照 AKUN：按下/抬起 = Touch|Identity，移动 = Position|Attribute
    uint32_t mask = (phase == HID_PHASE_MOVED)
                        ? (HID_MASK_POSITION | HID_MASK_ATTRIBUTE)
                        : (HID_MASK_TOUCH | HID_MASK_IDENTITY);

    IOHIDEventRef hand = _createHand(kCFAllocatorDefault, ts, HID_TYPE_HAND,
                                     0, 0, mask, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0,   // 坐标只放在 finger 子事件里（同 AKUN）
                                     0, touching);
    IOHIDEventRef finger = _createFinger(kCFAllocatorDefault, ts,
                                         HID_FINGER_ID, HID_FINGER_ID, mask,
                                         x, y, 0, 0, 90.0,
                                         touching, touching);   // range / touch 同 AKUN：按住在 in-range

    if (hand && finger) {
        // 这两项让系统认为事件来自内置触摸屏（AKUN 一样是必设的）
        _setInteger(hand, kHIDFieldIsBuiltIn, 1);
        _setInteger(hand, kHIDFieldDigitizerIsDisplayIntegrated, 1);
        if (_setFloat) {
            _setFloat(finger, kHIDFieldDigitizerMajorRadius, 5.0);
            _setFloat(finger, kHIDFieldDigitizerMinorRadius, 5.0);
        }
        _appendEvent(hand, finger, 0);
        if (_setSenderID) { _setSenderID(hand, kSenderID); }

        // 完全照 AKUN 的发法：串行队列 + CFRetain 后异步 dispatch，发完才 release。
        // 同步 dispatch 紧接着 CFRelease，事件常常还没走完 XPC 就被回收 → 表现就是“点了没反应”。
        static dispatch_queue_t hidQueue;
        static dispatch_once_t onceQueue;
        dispatch_once(&onceQueue, ^{
            dispatch_attr_t attr = DISPATCH_QUEUE_SERIAL;
            dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_USER_INTERACTIVE, 0);
            hidQueue = dispatch_queue_create("com.akun.bridge.hid", attr);
        });
        IOHIDEventRef strong = (IOHIDEventRef)CFRetain(hand);
        IOHIDEventSystemClientRef client = _client;
        DispatchEventFn send = _dispatch;
        dispatch_async(hidQueue, ^{
            send(client, strong);
            CFRelease(strong);
            NSLog(@"[inject] 已发 phase=%u mask=0x%x (%.3f, %.3f)", phase, mask, x, y);
        });
    }
    if (finger) { CFRelease(finger); }
    if (hand) { CFRelease(hand); }
}

- (void)handleCommand:(NSDictionary *)cmd {
    NSString *t = cmd[@"t"];
    if (![t isKindOfClass:[NSString class]]) { return; }
    // 网页端发来的是 0~1 归一化坐标；HID 注入同样吃 0~1，直接透传（越界夹一下）。
    // 之前乘成 414x736 的点坐标去喂 HID，等于每个触点都在屏幕外，表现就是点了没反应。
    CGSize sz = [self screenPointSize];
    double x = clamp01([cmd[@"x"] doubleValue]);
    double y = clamp01([cmd[@"y"] doubleValue]);

    static dispatch_once_t onceLog;
    dispatch_once(&onceLog, ^{
        NSLog(@"[inject] 屏 %.0fx%.0f 点，坐标按 0~1 归一化注入", sz.width, sz.height);
    });

    if ([t isEqualToString:@"d"]) {
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
    } else if ([t isEqualToString:@"m"]) {
        [self dispatchPhase:HID_PHASE_MOVED x:x y:y];
    } else if ([t isEqualToString:@"u"]) {
        [self dispatchPhase:HID_PHASE_ENDED x:x y:y];
    } else if ([t isEqualToString:@"tap"]) {
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
        usleep(60000);
        [self dispatchPhase:HID_PHASE_ENDED x:x y:y];
    } else if ([t isEqualToString:@"swipe"]) {
        double x2 = clamp01([cmd[@"x2"] doubleValue]);
        double y2 = clamp01([cmd[@"y2"] doubleValue]);
        int steps = 12;
        [self dispatchPhase:HID_PHASE_BEGAN x:x y:y];
        for (int i = 1; i <= steps; i++) {
            double k = (double)i / steps;
            [self dispatchPhase:HID_PHASE_MOVED x:x + (x2 - x) * k y:y + (y2 - y) * k];
            usleep(12000);
        }
        [self dispatchPhase:HID_PHASE_ENDED x:x2 y:y2];
    } else if ([t isEqualToString:@"k"]) {
        NSLog(@"[inject] key %@", cmd[@"code"]);
        [self dispatchKey:cmd[@"code"]];
    }
}

/// Home 手势：从下缘外往上滑，回桌面（坐标同样是 0~1）。
- (void)dispatchKey:(NSString *)code {
    if (![code isKindOfClass:[NSString class]]) { return; }
    if ([code isEqualToString:@"home"]) {
        [self dispatchPhase:HID_PHASE_BEGAN x:0.5 y:0.995];
        [self dispatchPhase:HID_PHASE_MOVED x:0.5 y:0.85];
        [self dispatchPhase:HID_PHASE_ENDED x:0.5 y:0.75];
    }
}

@end
