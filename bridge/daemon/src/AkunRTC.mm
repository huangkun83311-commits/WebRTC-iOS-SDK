#import "AkunRTC.h"
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrame.h>
#import <math.h>

@interface AkunRTC () <RTCPeerConnectionDelegate>
@property (nonatomic, copy) NSString *serverBase;
@property (nonatomic, copy) NSString *deviceId;

@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCVideoSource *videoSource;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) RTCVideoCapturer *capturer;
@property (nonatomic, strong) RTCPeerConnection *pc;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *ws;
@property (nonatomic, strong) NSMutableArray<RTCIceCandidate *> *pendingCandidates;
@property (nonatomic, assign) BOOL remoteDescriptionSet;
@property (nonatomic, assign) NSInteger reconnectAttempt;
@property (nonatomic, assign) NSUInteger pushedFrames;
@property (nonatomic, strong) RTCRtpSender *sender;

// 输出参数（对齐 AKUN 默认：0.35 / 12fps / 1.5Mbps）
@property (nonatomic, assign) double scale;
@property (nonatomic, assign) int targetFps;
@property (nonatomic, assign) NSInteger maxBitrateBps;
@property (nonatomic, assign) NSInteger sourceWidth;
@property (nonatomic, assign) NSInteger sourceHeight;
@property (nonatomic, assign) BOOL formatApplied;
@end

@implementation AkunRTC

- (instancetype)initWithServerBase:(NSString *)base deviceId:(NSString *)deviceId {
    if ((self = [super init])) {
        _serverBase = [base copy];
        _deviceId = [deviceId copy];
        _pendingCandidates = [NSMutableArray array];
        _scale = 0.35;
        _targetFps = 12;
        _maxBitrateBps = 1500000;
    }
    return self;
}

- (void)configureWithScale:(double)scale fps:(int)fps maxBitrateBps:(NSInteger)maxBitrateBps {
    self.scale = (scale > 0.05 && scale <= 1.0) ? scale : 0.35;
    self.targetFps = (fps > 0 && fps <= 60) ? fps : 12;
    self.maxBitrateBps = maxBitrateBps > 0 ? maxBitrateBps : 1500000;
    NSLog(@"[rtc] 输出参数 scale=%.2f fps=%d maxBitrate=%ld",
          self.scale, self.targetFps, (long)self.maxBitrateBps);
    if (self.pc) { [self applyOutputFormat]; }
}

/// 把 scale/fps 应用到视频源，同时给这条 RTP 流加码率上限（对应 AKUN 的 AverageBitRate）。
- (void)applyOutputFormat {
    if (!self.videoSource) { return; }

    if (self.sourceWidth > 0 && self.sourceHeight > 0) {
        int w = (int)lround((double)self.sourceWidth * self.scale);
        int h = (int)lround((double)self.sourceHeight * self.scale);
        // H.264 友好：宽高必须是偶数
        w -= (w % 2); h -= (h % 2);
        if (w < 64) { w = 64; }
        if (h < 64) { h = 64; }
        [self.videoSource adaptOutputFormatToWidth:w height:h fps:self.targetFps];
        NSLog(@"[rtc] 输出 %dx%d @%dfps（源 %ldx%ld，scale=%.2f）",
              w, h, self.targetFps, (long)self.sourceWidth, (long)self.sourceHeight, self.scale);
        self.formatApplied = YES;
    }

    if (self.maxBitrateBps > 0 && self.pc) {
        // 下限给足：默认起始码率很低，会先糊一阵再爬上来，局域网里没必要
        NSNumber *minRate = @(MAX(300000, (NSInteger)(self.maxBitrateBps * 0.5)));
        BOOL ok = [self.pc setBweMinBitrateBps:minRate
                             currentBitrateBps:@(self.maxBitrateBps)
                                 maxBitrateBps:@(self.maxBitrateBps)];
        NSLog(@"[rtc] 码率 %ld~%ld bps 设置%@", (long)minRate.integerValue,
              (long)self.maxBitrateBps, ok ? @"成功" : @"失败");
    }

    // 帧率上限 + 优先级：让 WebRTC 直接按我们要的节奏出帧，不要它自己再"平滑"一遍
    if (self.sender) {
        RTCRtpParameters *params = self.sender.parameters;
        if (params && params.encodings.count > 0) {
            RTCRtpEncodingParameters *enc = params.encodings.firstObject;
            enc.maxFramerate = @(self.targetFps);
            enc.maxBitrateBps = @(self.maxBitrateBps);
            enc.minBitrateBps = @(MIN(self.maxBitrateBps, MAX(300000, (NSInteger)(self.maxBitrateBps * 0.5)));
            enc.bitratePriority = 1.0;
            enc.networkPriority = RTCPriorityHigh;
            params.degradationPreference = @(RTCDegradationPreferenceMaintainFramerate);
            self.sender.parameters = params;
            NSLog(@"[rtc] 编码参数 maxFramerate=%d maxBitrate=%ld", self.targetFps,
                  (long)self.maxBitrateBps);
        }
    }
}

- (NSString *)wsURLString {
    NSString *base = self.serverBase ?: @"";
    if ([base hasPrefix:@"http://"]) {
        base = [@"ws://" stringByAppendingString:[base substringFromIndex:7]];
    } else if ([base hasPrefix:@"https://"]) {
        base = [@"wss://" stringByAppendingString:[base substringFromIndex:8]];
    }
    while ([base hasSuffix:@"/"]) {
        base = [base substringToIndex:base.length - 1];
    }
    return [NSString stringWithFormat:@"%@/ws?room=video-%@&role=publisher", base, self.deviceId];
}

#pragma mark - WebRTC 初始化

- (void)setupPeerConnection {
    RTCInitializeSSL();

    RTCDefaultVideoEncoderFactory *encoder = [[RTCDefaultVideoEncoderFactory alloc] init];
    RTCDefaultVideoDecoderFactory *decoder = [[RTCDefaultVideoDecoderFactory alloc] init];
    self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoder decoderFactory:decoder];

    self.videoSource = [self.factory videoSourceForScreenCast:YES];

    self.capturer = [[RTCVideoCapturer alloc] initWithDelegate:self.videoSource];
    self.videoTrack = [self.factory videoTrackWithSource:self.videoSource trackId:@"screen0"];

    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    // 局域网直连：不配 STUN/TURN，靠 host candidate 打洞。
    config.iceServers = @[];
    config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;

    RTCMediaConstraints *constraints =
        [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    self.pc = [self.factory peerConnectionWithConfiguration:config constraints:constraints delegate:self];
    self.sender = [self.pc addTrack:self.videoTrack streamIds:@[@"screen"]];

    // 带宽不够时优先保帧率、降分辨率（跟 AKUN 的「固定低帧率 + 缩放」一个取向），
    // 这样群控里手感不会越用越滞后。
    RTCRtpParameters *params = self.sender.parameters;
    if (params) {
        params.degradationPreference = @(RTCDegradationPreferenceMaintainFramerate);
        self.sender.parameters = params;
    }

    [self applyOutputFormat];
    NSLog(@"[rtc] peer connection 就绪");
}

#pragma mark - 信令

- (void)start {
    if (!self.pc) {
        [self setupPeerConnection];
    }

    if (self.serverBase.length == 0) {
        NSLog(@"[rtc] 还没有服务地址（自动发现中），信令暂不连接");
        return;
    }

    if (!self.session) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        self.session = [NSURLSession sessionWithConfiguration:cfg];
    }
    NSURL *url = [NSURL URLWithString:[self wsURLString]];
    if (!url) {
        NSLog(@"[rtc] 信令地址不合法: %@", [self wsURLString]);
        return;
    }
    NSLog(@"[rtc] 连接信令 %@", url);
    self.ws = [self.session webSocketTaskWithURL:url];
    [self.ws resume];
    [self receiveLoop];
}

- (void)receiveLoop {
    __weak typeof(self) weakSelf = self;
    [self.ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        if (error) {
            NSLog(@"[rtc] 信令断开: %@", error.localizedDescription);
            [self scheduleReconnect];
            return;
        }
        NSString *text = message.string;
        if (!text && message.data) {
            text = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
        }
        if (text.length) { [self handleSignal:text]; }
        [self receiveLoop];
    }];
}

- (void)scheduleReconnect {
    self.reconnectAttempt++;
    double delay = MIN(pow(2.0, (double)self.reconnectAttempt), 30.0);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        [self.ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        [self start];
    });
}

- (void)sendJSON:(NSDictionary *)dict {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) { return; }
    [self.ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text]
        completionHandler:^(NSError *error) {
            if (error) { NSLog(@"[rtc] 发送失败: %@", error.localizedDescription); }
        }];
}

- (void)handleSignal:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) { return; }
    NSString *type = obj[@"type"];

    if ([type isEqualToString:@"offer"]) {
        NSString *sdp = obj[@"sdp"];
        if (!sdp) { return; }
        RTCSessionDescription *offer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
        RTCPeerConnection *pc = self.pc;
        __weak typeof(pc) weakPC = pc;
        __weak typeof(self) weakSelf = self;

        [pc setRemoteDescription:offer completionHandler:^(NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { return; }
            if (error) {
                NSLog(@"[rtc] setRemoteDescription 失败: %@", error.localizedDescription);
                return;
            }
            strongSelf.remoteDescriptionSet = YES;
            [strongSelf flushCandidates];

            RTCMediaConstraints *c =
                [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
            RTCPeerConnection *strongPC = weakPC;
            [strongPC answerForConstraints:c completionHandler:^(RTCSessionDescription *answer, NSError *err) {
                if (!answer || err) {
                    NSLog(@"[rtc] createAnswer 失败: %@", err.localizedDescription);
                    return;
                }
                [strongPC setLocalDescription:answer completionHandler:^(NSError *e) {
                    if (e) {
                        NSLog(@"[rtc] setLocalDescription 失败: %@", e.localizedDescription);
                        return;
                    }
                    __strong typeof(weakSelf) s = weakSelf;
                    [s sendJSON:@{@"type": @"answer", @"sdp": answer.sdp ?: @""}];
                    NSLog(@"[rtc] 已回 answer");
                }];
            }];
        }];
    } else if ([type isEqualToString:@"candidate"]) {
        NSString *sdp = obj[@"candidate"];
        NSNumber *idx = obj[@"sdpMLineIndex"];
        NSString *mid = obj[@"sdpMid"];
        if (!sdp) { return; }
        RTCIceCandidate *cand = [[RTCIceCandidate alloc] initWithSdp:sdp
                                                      sdpMLineIndex:(int32_t)idx.intValue
                                                           sdpMid:mid];
        if (self.remoteDescriptionSet) {
            [self.pc addIceCandidate:cand completionHandler:^(NSError *e) {}];
        } else {
            [self.pendingCandidates addObject:cand];
        }
    }
}

- (void)flushCandidates {
    for (RTCIceCandidate *c in self.pendingCandidates) {
        [self.pc addIceCandidate:c completionHandler:^(NSError *e) {}];
    }
    [self.pendingCandidates removeAllObjects];
}

#pragma mark - 推帧

- (void)pushPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!self.videoSource || !pixelBuffer) { return; }

    // 首帧拿到真实屏幕尺寸后再算输出尺寸：scale 0.35 → 1170×2532 变成约 410×886
    if (self.sourceWidth == 0 || self.sourceHeight == 0) {
        self.sourceWidth = (NSInteger)CVPixelBufferGetWidth(pixelBuffer);
        self.sourceHeight = (NSInteger)CVPixelBufferGetHeight(pixelBuffer);
        [self applyOutputFormat];
    }

    RTCCVPixelBuffer *buffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    int64_t ns = (int64_t)(CACurrentMediaTime() * 1000000000.0);
    RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:buffer
                                                        rotation:RTCVideoRotation_0
                                                     timeStampNs:ns];
    [self.videoSource capturer:self.capturer didCaptureVideoFrame:frame];

    self.pushedFrames++;
    if (self.pushedFrames % 150 == 0) {
        NSLog(@"[rtc] 已推 %lu 帧", (unsigned long)self.pushedFrames);
    }
}

- (void)stop {
    [self.ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.ws = nil;
    [self.pc close];
    self.pc = nil;
}

- (void)reconnectWithServerBase:(NSString *)base {
    if (base.length == 0) { return; }
    if (self.ws && [self.serverBase isEqualToString:base]) { return; }
    self.serverBase = [base copy];
    NSLog(@"[rtc] 信令端点切到 %@", base);
    [self.ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.ws = nil;
    self.reconnectAttempt = 0;
    [self start];
}

#pragma mark - RTCPeerConnectionDelegate（这个 SDK 版本前 9 个方法非 optional，必须实现）

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    NSLog(@"[rtc] signaling state -> %ld", (long)stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSLog(@"[rtc] ice state -> %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    [self sendJSON:@{
        @"type": @"candidate",
        @"candidate": candidate.sdp ?: @"",
        @"sdpMid": candidate.sdpMid ?: @"",
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {}

#pragma mark - 可选部分

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeConnectionState:(RTCPeerConnectionState)newState {
    NSLog(@"[rtc] connection state -> %ld", (long)newState);
}

@end