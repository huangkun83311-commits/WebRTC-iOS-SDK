#ifndef AkunCapture_h
#define AkunCapture_h

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

/**
 屏幕抓取：走 IOMobileFramebuffer 拿到当前显示层的 IOSurface，
 每帧把像素锁住交给回调（CVPixelBuffer，BGRA）。

 为什么不用 ReplayKit：守护进程里没有 UI，也拿不到 RPScreenRecorder；
 这条路是私有 API，需要 com.apple.private.IOSurface.protected-access
 与 IOKit userclient 白名单，权限在 entitlements 里。
 */
@interface AkunCapture : NSObject

@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
/// 屏幕真实像素尺寸（未缩放，坐标映射用这个）
@property (nonatomic, readonly) NSInteger screenWidth;
@property (nonatomic, readonly) NSInteger screenHeight;

/// 出图缩放：渲染服务器按 屏像素 × scale 直接出图（GPU 缩放，省掉 CPU 逐帧缩放）
@property (nonatomic, assign) double outputScale;

/// 抓屏帧率，默认 12（对齐 AKUN 的出厂默认；30fps 在群控场景里只会白烧 CPU 和带宽）。
@property (nonatomic, assign) int fps;

/// 每帧回调（在内部串行队列上调用）。返回的 pixelBuffer 在回调返回后失效。
@property (nonatomic, copy) void (^frameHandler)(CVPixelBufferRef pixelBuffer);

/// 起/停。start 返回 NO 表示拿不到显示层（权限或 API 不匹配）。
- (BOOL)start;
- (void)stop;

/// 抓一张当前屏幕的静帧（JPEG）。scale=1 是屏幕原生像素，quality 0~1。
/// 中控的截图指令走这里：独立建一块临时 surface 渲染，不干扰推流那条双缓冲。
- (NSData *)snapshotJPEGWithScale:(double)scale quality:(double)quality;

@end

#endif