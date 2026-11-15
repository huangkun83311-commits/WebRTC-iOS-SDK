#import <Foundation/Foundation.h>

/// 设备当前旋转象限（0=0°，1=90°CW，2=180°，3=270°CW），全局唯一。
/// 抓屏推流时随帧带上去（RTCVideoFrame rotation），坐标注入时用它反算回竖屏像素，
/// 这样「手机横过来 → 电脑看到的画面也横过来，点哪就是哪」——和 AKUN 的 OrientationSync 一致。
@interface AkunOrientation : NSObject

+ (int)quad;
+ (void)setQuad:(int)q;
+ (BOOL)isPortraitUpsideDown;
/// 起监听（FBSOrientationObserver，FrontBoardServices 私有类，只在真机有效）
+ (BOOL)startObserving;
+ (void)stopObserving;

@end
