//  AkunInjector — 触摸注入入口
//
//  这里不再自己拼 IOHIDEvent：直接把 AKUN（TrollVNC）的 STHIDEventGenerator 原样搬进
//  src/vendor/ 逐字复用（它是真机验证过能控制 SpringBoard 的那一份）。
//  我们自己手搓的版本试过归一化坐标、掩码、异步发送、senderID 等多种组合，控制始终无效果，
//  所以改成"用它的代码、只换传输层为 WebRTC"。
//
//  注意坐标口：STHIDEventGenerator 收的是**屏幕像素坐标**，内部自己除以
//  _unjailedReferenceBoundsInPixels（1080x1920）再喂 HID，所以网页来的 0~1 要先乘回来。

#import "AkunInjector.h"

// 全局：最后一次触摸注入的时刻（给抓屏侧算「点击→出帧」用）
double gLastInputMono = 0.0;

// 抓屏侧提供的「跟手升帧」钩子：每次注入输入就通知它，抓屏会在 1.2 秒内抬到 40fps
extern void AkunBridgeNoteInteraction(void);
#import "AkunOrientation.h"

#import <UIKit/UIKit.h>

#import "vendor/STHIDEventGenerator.h"
#import "vendor/Logging.h"
#import "vendor/UIScreen+Private.h"

// STHIDEventGenerator 依赖的外部符号
BOOL tvncLoggingEnabled = NO;
BOOL tvncVerboseLoggingEnabled = NO;
int gOrientationFixQuad = 0;

// 这几个入口在 .h 里没有，但 AKUN 的 vnc 服务就是直接这么调的（见 trollvncserver.mm ptrAddEvent）
@interface STHIDEventGenerator (AkunPrivateTouch)
- (void)touchDownAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)liftUpAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)_updateTouchPoints:(CGPoint *)points count:(NSUInteger)count;
- (CGSize)akun_physicalScreenSize;
@end

@implementation AkunInjector {
    double _startX;   // 0~1
    double _startY;
    double _lastX;
    double _lastY;
    BOOL _dragging;
    double _downTime;
}

- (instancetype)init {
    if ((self = [super init])) {
        tvncLoggingEnabled = YES;   // 它内部的 TVLog 走 NSLog，方便真机排错
        NSLog(@"[inject] 使用 AKUN STHIDEventGenerator 注入");
    }
    return self;
}

/// 屏幕像素尺寸：**必须**用 generator 内部同一份基准，
/// 它据此除以归一化（我们这边若用别的尺寸，落点就会整体偏移）。
- (CGSize)pixelSize {
    CGSize s = CGSizeZero;
    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    s = [gen akun_physicalScreenSize];
    if (s.width < 1 || s.height < 1) {
        CGRect r = CGRectZero;
        @try {
            r = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels];
        } @catch (NSException *e) {
        }
        if (r.size.width < 1 || r.size.height < 1) {
            r = CGRectMake(0, 0, 1080, 1920);
        }
        s = r.size;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[inject] generator 归一化基准 = %.0fx%.0f", s.width, s.height);
    });
    return s;
}

static double clamp01(double v) {
    if (v < 0) { return 0; }
    if (v > 1) { return 1; }
    return v;
}

/// 归一化坐标 → 竖屏物理像素。
/// quad != 0 时，客户端看到的是「转过的画面」，这里按 AKUN 的 vncPointToDevicePoint
/// 反向旋转，保证点哪就是哪（不修这段，横屏下点按会整体偏、甚至点不中）。
- (CGPoint)pointFromNormX:(double)x y:(double)y {
    CGSize s = [self pixelSize];
    double W = s.width, H = s.height;
    double nx = clamp01(x), ny = clamp01(y);
    int q = [AkunOrientation quad];

    // 旋转后的舞台尺寸
    double rotW = (q % 2 == 0) ? W : H;
    double rotH = (q % 2 == 0) ? H : W;
    double stX = nx * rotW;
    double stY = ny * rotH;

    double dx = 0, dy = 0;
    switch (q) {
    case 1:  // 90°CW：stageX = srcH-1-srcY, stageY = srcX  =>  srcX = stageY, srcY = srcH-1-stageX
        dx = stY;
        dy = (H - 1) - stX;
        break;
    case 2:  // 180°
        dx = (W - 1) - stX;
        dy = (H - 1) - stY;
        break;
    case 3:  // 270°CW
        dx = (W - 1) - stY;
        dy = stX;
        break;
    case 0:
    default:
        dx = stX;
        dy = stY;
        break;
    }
    if (dx < 0) { dx = 0; }
    if (dy < 0) { dy = 0; }
    if (dx > W - 1) { dx = W - 1; }
    if (dy > H - 1) { dy = H - 1; }
    return CGPointMake(dx, dy);
}

- (void)handleCommand:(NSDictionary *)cmd {
    NSString *t = cmd[@"t"];
    if (![t isKindOfClass:[NSString class]]) { return; }

    double x = clamp01([cmd[@"x"] doubleValue]);
    double y = clamp01([cmd[@"y"] doubleValue]);

    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];

    if ([t isEqualToString:@"tap"]) {
        CGPoint p = [self pointFromNormX:x y:y];
        NSLog(@"[inject] tap 像素 (%f,%f)", p.x, p.y);
        // 不用 gen 的 tap: —— 它内部 _sendTaps 断言 delay>0 而自身传 0，带断言编译会 abort。
        // 走 touchDown/touchUp 两段，等价 AKUN 的 tap 行为。
        gLastInputMono = CACurrentMediaTime();
        AkunBridgeNoteInteraction();   // 进交互窗口：抓屏强制出帧 + 抬码率
        [gen touchDownAtPoints:&p touchCount:1];
        // 对齐 AKUN：STHIDEventGenerator 里 fingerLiftDelay = 0.05，即「按下→50ms→抬起」
        NSUInteger ms = cmd[@"ms"] ? [cmd[@"ms"] unsignedIntValue] : 50;
        if (ms < 30) { ms = 30; }
        if (ms > 800) { ms = 800; }
        usleep((useconds_t)(ms * 1000));
        [gen liftUpAtPoints:&p touchCount:1];
        NSLog(@"[inject] tap 完成（按住 %lu ms）", (unsigned long)ms);
    } else if ([t isEqualToString:@"d"]) {
        // 与 AKUN ptrAddEvent 一致：按下发 touchDown，移动发 _updateTouchPoints，抬起发 liftUp
        _dragging = YES;
        _startX = x; _startY = y; _lastX = x; _lastY = y;
        _downTime = CACurrentMediaTime();
        CGPoint p = [self pointFromNormX:x y:y];
        NSLog(@"[inject] down (%f,%f)", p.x, p.y);
        gLastInputMono = CACurrentMediaTime();
        AkunBridgeNoteInteraction();
        [gen touchDownAtPoints:&p touchCount:1];
    } else if ([t isEqualToString:@"m"]) {
        if (_dragging) {
            _lastX = x; _lastY = y;
            CGPoint p = [self pointFromNormX:x y:y];
            [gen _updateTouchPoints:&p count:1];
        }
    } else if ([t isEqualToString:@"u"]) {
        if (_dragging) {
            _dragging = NO;
            CGPoint b = [self pointFromNormX:(x > 0 ? x : _lastX) y:(y > 0 ? y : _lastY)];
            // 最短按住 60ms：网页鼠标点按常常只有 20~40ms，SpringBoard 会当成无效触摸丢掉；
            // 但按太久也会直接加延迟（触摸是松手才生效），60ms 是「不被丢」和「不拖」的折中
            double held = CACurrentMediaTime() - _downTime;
            if (held < 0.05) { usleep((useconds_t)((0.05 - held) * 1e6)); }
            NSLog(@"[inject] up (%f,%f) 按住 %.0fms", b.x, b.y, held * 1000);
            [gen liftUpAtPoints:&b touchCount:1];
        }
    } else if ([t isEqualToString:@"dtap"]) {
        // 双击：走 AKUN 的 doubleTap（内部间隔 0.15s），比网页连发两次单击更可靠
        CGPoint p = [self pointFromNormX:x y:y];
        NSLog(@"[inject] dtap (%f,%f)", p.x, p.y);
        gLastInputMono = CACurrentMediaTime();
        AkunBridgeNoteInteraction();
        [gen doubleTap:p];
    } else if ([t isEqualToString:@"swipe"]) {
        CGPoint a = [self pointFromNormX:x y:y];
        CGPoint b = [self pointFromNormX:[cmd[@"x2"] doubleValue] y:[cmd[@"y2"] doubleValue]];
        AkunBridgeNoteInteraction();
        [gen dragLinearWithStartPoint:a endPoint:b duration:0.25];
    } else if ([t isEqualToString:@"k"]) {
        NSString *code = cmd[@"code"];
        if ([code isEqualToString:@"home"]) {
            // 以前这里既不打点也不记时刻，导致「按 home → 画面」这段无法被 [lat] 量到
            gLastInputMono = CACurrentMediaTime();
            AkunBridgeNoteInteraction();
            NSLog(@"[inject] home");
            [gen menuPress];
        }
    } else if ([t isEqualToString:@"hk"]) {
        unsigned int usage = [cmd[@"usage"] unsignedIntValue];
        if (usage == 0xE9) { [gen volumeIncrementPress]; }
        else if (usage == 0xEA) { [gen volumeDecrementPress]; }
        else if (usage == 0x223) { [gen menuPress]; }
    }
}

@end
