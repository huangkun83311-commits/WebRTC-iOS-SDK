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
@end

@implementation AkunInjector {
    double _startX;   // 0~1
    double _startY;
    double _lastX;
    double _lastY;
    BOOL _dragging;
}

- (instancetype)init {
    if ((self = [super init])) {
        tvncLoggingEnabled = YES;   // 它内部的 TVLog 走 NSLog，方便真机排错
        NSLog(@"[inject] 使用 AKUN STHIDEventGenerator 注入");
    }
    return self;
}

/// 屏幕像素尺寸（AKUN 内部也是拿这个做归一化基准：1080x1920）
- (CGSize)pixelSize {
    CGRect r = CGRectZero;
    @try {
        r = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels];
    } @catch (NSException *e) {
    }
    if (r.size.width < 1 || r.size.height < 1) {
        r = CGRectMake(0, 0, 1080, 1920);
    }
    return r.size;
}

static double clamp01(double v) {
    if (v < 0) { return 0; }
    if (v > 1) { return 1; }
    return v;
}

- (CGPoint)pointFromNormX:(double)x y:(double)y {
    CGSize s = [self pixelSize];
    return CGPointMake(clamp01(x) * s.width, clamp01(y) * s.height);
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
        [gen touchDownAtPoints:&p touchCount:1];
        NSUInteger ms = cmd[@"ms"] ? [cmd[@"ms"] unsignedIntValue] : 120;
        if (ms < 30) { ms = 30; }
        if (ms > 800) { ms = 800; }
        usleep((useconds_t)(ms * 1000));
        [gen liftUpAtPoints:&p touchCount:1];
        NSLog(@"[inject] tap 完成（按住 %lu ms）", (unsigned long)ms);
    } else if ([t isEqualToString:@"d"]) {
        // 与 AKUN ptrAddEvent 一致：按下发 touchDown，移动发 _updateTouchPoints，抬起发 liftUp
        _dragging = YES;
        _startX = x; _startY = y; _lastX = x; _lastY = y;
        CGPoint p = [self pointFromNormX:x y:y];
        NSLog(@"[inject] down (%f,%f)", p.x, p.y);
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
            NSLog(@"[inject] up (%f,%f)", b.x, b.y);
            [gen liftUpAtPoints:&b touchCount:1];
        }
    } else if ([t isEqualToString:@"swipe"]) {
        CGPoint a = [self pointFromNormX:x y:y];
        CGPoint b = [self pointFromNormX:[cmd[@"x2"] doubleValue] y:[cmd[@"y2"] doubleValue]];
        [gen dragLinearWithStartPoint:a endPoint:b duration:0.25];
    } else if ([t isEqualToString:@"k"]) {
        NSString *code = cmd[@"code"];
        if ([code isEqualToString:@"home"]) {
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
