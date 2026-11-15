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
        // 不能用 gen 的 tap: —— 它内部 _sendTaps 里断言 delay > 0，而 tap: 传的是 0，
        // 带断言编译（我们这份）会直接 abort；改按下/抬起两段，节奏与 AKUN 一致
        // （fingerLiftDelay = 50ms），且每段各自带 marker 事件。
        [gen touchDown:p];
        // 按住时长可调（默认 120ms）：几十毫秒的"闪电点"SpringBoard 未必认，真实手指点按约 100~150ms
        NSUInteger ms = cmd[@"ms"] ? [cmd[@"ms"] unsignedIntValue] : 120;
        if (ms < 30) { ms = 30; }
        if (ms > 800) { ms = 800; }
        NSLog(@"[inject] 按住 %lu ms", (unsigned long)ms);
        usleep((useconds_t)(ms * 1000));
        [gen liftUp:p];
        NSLog(@"[inject] tap 调用返回");
    } else if ([t isEqualToString:@"d"]) {
        _dragging = YES;
        _startX = x; _startY = y; _lastX = x; _lastY = y;
    } else if ([t isEqualToString:@"m"]) {
        if (_dragging) { _lastX = x; _lastY = y; }
    } else if ([t isEqualToString:@"u"]) {
        if (_dragging) {
            _dragging = NO;
            CGPoint a = [self pointFromNormX:_startX y:_startY];
            CGPoint b = [self pointFromNormX:(x > 0 ? x : _lastX) y:(y > 0 ? y : _lastY)];
            if (fabs(b.x - a.x) + fabs(b.y - a.y) > 2) {
                [gen dragLinearWithStartPoint:a endPoint:b duration:0.25];
            }
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
