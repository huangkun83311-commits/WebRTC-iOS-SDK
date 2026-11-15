#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <WebRTC/WebRTC.h>

/**
 WebRTC 推流端：浏览器发 recvonly offer，本端答 answer 并挂上屏幕轨。
 信令走自建中继（/ws?room=video-<id>&role=publisher），与 IPA 那套完全同一套协议。
 */
@interface AkunRTC : NSObject

- (instancetype)initWithServerBase:(NSString *)base deviceId:(NSString *)deviceId;

/// 由抓屏回调喂帧。
- (void)pushPixelBuffer:(CVPixelBufferRef)pixelBuffer;

- (void)start;
- (void)stop;

/// 自动发现拿到新地址后切换信令端点（不重建 PeerConnection，只重连 WS）。
- (void)reconnectWithServerBase:(NSString *)base;

@end