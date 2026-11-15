#import "AkunRTC.h"
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrame.h>

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
@end

@implementation AkunRTC

- (instancetype)initWithServerBase:(NSString *)base deviceId:(NSString *)deviceId {
    if ((self = [super init])) {
        _serverBase = [base copy];
        _deviceId = [deviceId copy];
        _pendingCandidates = [NSMutableArray array];
    }
    return self;
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
    [self.videoSource adaptOutputFormatToWidth:720 height:1280 fps:30];

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
    [self.pc addTrack:self.videoTrack streamIds:@[@"screen"]];
    NSLog(@"[rtc] peer connection 就绪");
}

#pragma mark - 信令

- (void)start {
    if (!self.pc) {
        [self setupPeerConnection];
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