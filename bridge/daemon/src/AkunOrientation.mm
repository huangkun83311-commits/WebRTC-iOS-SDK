//  AkunOrientation — 跟随设备旋转
//
//  用 FrontBoardServices 的 FBSOrientationObserver（跟 AKUN 一模一样），
//  它给的是「当前界面朝向」，App 横过来就会回调。
//  拿不到这个类时降级为只读 UIDevice orientation 静态值（不崩、不阻塞启动）。

#import "AkunOrientation.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>

#import "vendor/FBSOrientationObserver.h"

static int gQuad = 0;   // 0/1/2/3 = 0/90/180/270 顺时针

@implementation AkunOrientation

+ (int)quad {
    return gQuad & 3;
}

+ (void)setQuad:(int)q {
    gQuad = q & 3;
    NSLog(@"[orient] quad=%d", gQuad);
}

+ (BOOL)isPortraitUpsideDown {
    return (gQuad & 3) == 2;
}

/// UIInterfaceOrientation → 顺时针象限（和 AKUN rotationForOrientation 一致）
static int quadForOrientation(UIInterfaceOrientation o) {
    switch (o) {
    case UIInterfaceOrientationPortraitUpsideDown:
        return 2;
    case UIInterfaceOrientationLandscapeLeft:
        return 1;   // 90° CW
    case UIInterfaceOrientationLandscapeRight:
        return 3;   // 270° CW
    case UIInterfaceOrientationPortrait:
    default:
        return 0;
    }
}

static FBSOrientationObserver *gObserver;

+ (BOOL)startObserving {
    Class cls = NSClassFromString(@"FBSOrientationObserver");
    if (!cls) {
        NSLog(@"[orient] 没有 FBSOrientationObserver（这台机器不支持跟随旋转），固定竖屏");
        return NO;
    }
    gObserver = [[cls alloc] init];
    if (!gObserver) {
        NSLog(@"[orient] FBSOrientationObserver 创建失败");
        return NO;
    }

    void (^handler)(FBSOrientationUpdate *) = ^(FBSOrientationUpdate *update) {
        if (!update) { return; }
        int q = quadForOrientation([update orientation]);
        if (q != gQuad) {
            NSLog(@"[orient] 旋转 quad %d -> %d", gQuad, q);
            gQuad = q;
        }
    };
    [gObserver setHandler:handler];

    // 先取一次当前朝向，否则首帧可能还是竖的
    @try {
        UIInterfaceOrientation cur = [gObserver activeInterfaceOrientation];
        gQuad = quadForOrientation(cur);
    } @catch (NSException *e) {
        NSLog(@"[orient] 取当前朝向异常: %@", e.reason);
    }
    NSLog(@"[orient] 已监听旋转，初始 quad=%d", gQuad);
    return YES;
}

+ (void)stopObserving {
    @try { [gObserver invalidate]; } @catch (NSException *e) {}
    gObserver = nil;
}

@end
