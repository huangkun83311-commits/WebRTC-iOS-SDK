#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <WebRTC/WebRTC.h>

/**
 WebRTC 推流端：浏览器发 recvonly offer，本端答 answer 并挂上屏幕轨。
 信令走自建中继（/ws?room=video-<id>&role=publisher），与 IPA 那套完全同一套协议。

 输出参数对齐 AKUN 的出厂默认（scale 0.35 / 12fps / 1.5Mbps 上限）：
 这三个值是它能在 30M 上传、几十台设备下保持不卡的原因，不是 VNC 协议本身。
 */
@interface AkunRTC : NSObject

- (instancetype)initWithServerBase:(NSString *)base deviceId:(NSString *)deviceId;

/// 输出参数：scale 0.1~1.0，fps 建议 3~30，maxBitrateBps 0 表示不限。默认 0.35 / 12 / 1.5M。
- (void)setBurstBitrateBps:(NSInteger)bps;
- (void)endBurstBitrate;
- (void)configureWithScale:(double)scale fps:(int)fps maxBitrateBps:(NSInteger)maxBitrateBps;

/// 由抓屏回调喂帧。首帧到达时会按 scale 计算输出尺寸（adaptOutputFormat）。
- (void)pushPixelBuffer:(CVPixelBufferRef)pixelBuffer;

- (void)start;
- (void)stop;

/// 自动发现拿到新地址后切换信令端点（不重建 PeerConnection，只重连 WS）。
- (void)reconnectWithServerBase:(NSString *)base;

/// 自适应：按实时丢包 / 往返时延自动降（或恢复）清晰度，回调里给出新的抓屏 scale。
/// 只在 [0.30, 用户设定值] 之间动，字体清晰度的下限 0.30 不会被突破。
@property (nonatomic, copy) void (^adaptiveScaleHandler)(double scale);

/// 设置自适应基线（清晰度/码率上限）；自适应只在基线以下活动。
- (void)setAdaptiveBaseScale:(double)baseScale bitrate:(NSInteger)baseBitrateBps;

@end
