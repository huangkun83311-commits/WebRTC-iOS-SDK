#import "AkunRTC.h"
#import "AkunOrientation.h"
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCStatisticsReport.h>
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
@property (nonatomic, assign) int appliedQuad;   // 上次套用输出格式时的象限

// ---- 自适应 ----
@property (nonatomic, assign) BOOL adaptiveEnabled;
@property (nonatomic, assign) double baseScale;         // 用户/中控设定的清晰度上限
@property (nonatomic, assign) NSInteger baseBitrateBps; // 用户/中控设定的码率上限
@property (nonatomic, assign) double adaptScale;        // 当前自适应生效的 scale
@property (nonatomic, assign) NSInteger adaptBitrateBps;
@property (nonatomic, strong) NSTimer *statTimer;
@property (nonatomic, assign) NSUInteger goodStreak;    // 连续健康次数（升档需要）
@property (nonatomic, assign) NSUInteger badStreak;     // 连续拥塞次数（降档需要）
@property (nonatomic, assign) double lastFramesEncoded;
@property (nonatomic, assign) double lastBytesSent;      // 上一窗口的累计发送字节
@property (nonatomic, assign) double lastStatsTimestamp; // 上一窗口时间戳（微秒）
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
        _adaptiveEnabled = YES;
        _baseScale = 0.35;
        _baseBitrateBps = 1500000;
        _adaptScale = 0.35;
        _adaptBitrateBps = 1500000;
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

/// 设置自适应基线（用户/中控想要的清晰度与码率上限）；自适应只在这个值以下活动。
- (void)setAdaptiveBaseScale:(double)baseScale bitrate:(NSInteger)baseBitrateBps {
    if (baseScale > 0.05 && baseScale <= 1.0) {
        self.baseScale = baseScale;
        self.adaptScale = baseScale;
    }
    if (baseBitrateBps > 0) {
        self.baseBitrateBps = baseBitrateBps;
        self.adaptBitrateBps = baseBitrateBps;
    }
    self.goodStreak = 0;
    self.badStreak = 0;
    if (self.sender) {
        RTCRtpParameters *params = self.sender.parameters;
        if (params && params.encodings.count > 0) {
            RTCRtpEncodingParameters *enc = params.encodings.firstObject;
            enc.maxBitrateBps = @(self.adaptBitrateBps);
            enc.minBitrateBps = @(MIN(self.adaptBitrateBps, MAX(300000, (NSInteger)(self.adaptBitrateBps * 0.5))));
            self.sender.parameters = params;
        }
    }
    NSLog(@"[adapt] 基线 scale=%.2f bitrate=%ld", self.adaptScale, (long)self.adaptBitrateBps);
}

/// 把 scale/fps 应用到视频源，同时给这条 RTP 流加码率上限（对应 AKUN 的 AverageBitRate）。
- (void)applyOutputFormat {
    if (!self.videoSource) { return; }

    if (self.sourceWidth > 0 && self.sourceHeight > 0) {
        int w = (int)lround((double)self.sourceWidth * self.scale);
        int h = (int)lround((double)self.sourceHeight * self.scale);
        // 关键：抓屏图始终是「竖屏 framebuffer」，quad 为奇数时帧会在编码前被转 90°，
        // 转完的尺寸是 h×w。这里请求的尺寸必须跟转向后的尺寸一致，
        // 否则编码器会按错的尺寸裁切 —— 表现就是「画面只显示一半」。
        if ([AkunOrientation quad] % 2 == 1) {
            int t = w; w = h; h = t;
        }
        // H.264 友好：宽高必须是偶数
        w -= (w % 2); h -= (h % 2);
        if (w < 64) { w = 64; }
        if (h < 64) { h = 64; }
        [self.videoSource adaptOutputFormatToWidth:w height:h fps:self.targetFps];
        NSLog(@"[rtc] 输出 %dx%d @%dfps（源 %ldx%ld，scale=%.2f）",
              w, h, self.targetFps, (long)self.sourceWidth, (long)self.sourceHeight, self.scale);
        self.formatApplied = YES;
        self.appliedQuad = [AkunOrientation quad];
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
            NSInteger minRate = MIN(self.maxBitrateBps, MAX(300000, (NSInteger)(self.maxBitrateBps * 0.5)));
            enc.minBitrateBps = @(minRate);
            enc.bitratePriority = 1.0;
            enc.networkPriority = RTCPriorityHigh;
            params.degradationPreference = @(RTCDegradationPreferenceMaintainResolution);
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
    [self startStatTimer];
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

#pragma mark - 自适应（丢包/时延 → 自动降清晰度，保住帧率）

/// 每 2 秒看一次远端反馈：丢包率、往返时延。
/// 判断依据只用「接收端真的丢了多少、来回多久」，不看编码器自报的码率，
/// 因为群控场景里卡顿几乎都来自上行带宽/网络抖动，而不是编码能力。
- (void)pollStats {
    if (!self.pc || !self.adaptiveEnabled) { return; }
    __weak typeof(self) weakSelf = self;
    [self.pc statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        [self handleStatsReport:report];
    }];
}

- (void)handleStatsReport:(RTCStatisticsReport *)report {
    if (!report) { return; }
    double fractionLost = -1.0;
    double rttSeconds = -1.0;
    double framesEncoded = -1.0;
    double totalEncodeTime = -1.0;
    double bytesSent = -1.0;
    double statsTs = report.timestamp_us;

    for (NSString *key in report.statistics) {
        RTCStatistics *st = report.statistics[key];
        NSDictionary *v = st.values;
        NSString *kind = [v[@"kind"] isKindOfClass:[NSString class]] ? (NSString *)v[@"kind"] : @"";
        if (![kind isEqualToString:@"video"]) { continue; }
        if ([st.type isEqualToString:@"remote-inbound-rtp"]) {
            if ([v[@"fractionLost"] isKindOfClass:[NSNumber class]]) {
                fractionLost = [v[@"fractionLost"] doubleValue];
            }
            if ([v[@"roundTripTime"] isKindOfClass:[NSNumber class]]) {
                rttSeconds = [v[@"roundTripTime"] doubleValue];
            }
        } else if ([st.type isEqualToString:@"outbound-rtp"]) {
            if ([v[@"framesEncoded"] isKindOfClass:[NSNumber class]]) {
                framesEncoded = [v[@"framesEncoded"] doubleValue];
            }
            if ([v[@"bytesSent"] isKindOfClass:[NSNumber class]]) {
                bytesSent = [v[@"bytesSent"] doubleValue];
            }
            if ([v[@"totalEncodeTime"] isKindOfClass:[NSNumber class]]) {
                totalEncodeTime = [v[@"totalEncodeTime"] doubleValue];
            }
        }
    }

    // 没有远端反馈（还没收到 RTCP）时不做判断
    if (fractionLost < 0 && rttSeconds < 0 && framesEncoded < 0) { return; }

    BOOL congested = NO;
    if (fractionLost > 0.05) { congested = YES; }        // 丢包 >5% 就是网络扛不住了
    if (rttSeconds > 0.25) { congested = YES; }          // 时延 >250ms，手感已经明显拖
    // 编码跟不上（单帧编码时间 > 12ms，A11 上意味着渲染→编码这条链在排队）
    if (framesEncoded > 0 && totalEncodeTime > 0) {
        double avgMs = (totalEncodeTime / framesEncoded) * 1000.0;
        if (avgMs > 12.0) { congested = YES; }
    }

    if (congested) {
        self.badStreak++;
        self.goodStreak = 0;
        // 连续两次（≈4 秒）都拥塞才降，避免一次网络抖动就来回跳档
        if (self.badStreak >= 2) { [self stepDown]; }
    } else {
        self.goodStreak++;
        self.badStreak = 0;
        // 连续 3 次（≈6 秒）健康才升档，升得慢，降得快
        if (self.goodStreak >= 3) { [self stepUp]; }
    }

    // 真实上行码率：用发送字节增量算，这才是「每台设备吃多少上行」的确数
    double kbps = -1.0;
    if (bytesSent >= 0 && self.lastBytesSent > 0 && self.lastStatsTimestamp > 0 && statsTs > self.lastStatsTimestamp) {
        double dt = (statsTs - self.lastStatsTimestamp) / 1000000.0;
        if (dt > 0.2) { kbps = (bytesSent - self.lastBytesSent) * 8.0 / 1000.0 / dt; }
    }
    if (bytesSent >= 0) { self.lastBytesSent = bytesSent; }
    if (statsTs > 0) { self.lastStatsTimestamp = statsTs; }

    NSLog(@"[adapt] 上行=%.0fkbps 丢包=%.1f%% rtt=%.0fms 编码=%.1fms scale=%.2f 上限=%ldbps",
          kbps,
          fractionLost > 0 ? fractionLost * 100.0 : -1.0,
          rttSeconds > 0 ? rttSeconds * 1000.0 : -1.0,
          (framesEncoded > 0 && totalEncodeTime > 0) ? (totalEncodeTime / framesEncoded) * 1000.0 : -1.0,
          self.adaptScale, (long)self.adaptBitrateBps);
}

- (void)applyAdaptiveValues {
    if (self.adaptiveScaleHandler) { self.adaptiveScaleHandler(self.adaptScale); }
    if (self.sender) {
        RTCRtpParameters *params = self.sender.parameters;
        if (params && params.encodings.count > 0) {
            RTCRtpEncodingParameters *enc = params.encodings.firstObject;
            enc.maxBitrateBps = @(self.adaptBitrateBps);
            self.sender.parameters = params;
        }
    }
    if (self.pc) {
        [self.pc setBweMinBitrateBps:@(MAX(200000, self.adaptBitrateBps / 2))
                    currentBitrateBps:@(self.adaptBitrateBps)
                        maxBitrateBps:@(self.adaptBitrateBps)];
    }
}

- (void)stepDown {
    double ns = self.adaptScale - 0.03;
    if (ns < 0.30) { ns = 0.30; }          // 字体可读下限，不再往下掉
    NSInteger nb = (NSInteger)(self.adaptBitrateBps * 0.8);
    if (nb < 350000) { nb = 350000; }      // 再省也要留够动态画面的码率
    if (fabs(ns - self.adaptScale) < 0.001 && nb == self.adaptBitrateBps) { return; }
    self.adaptScale = ns;
    self.adaptBitrateBps = nb;
    self.goodStreak = 0;
    [self applyAdaptiveValues];
    NSLog(@"[adapt] 网络拥塞 → 降档 scale=%.2f bitrate=%ld（保帧率优先）", ns, (long)nb);
}

- (void)stepUp {
    double ns = self.adaptScale + 0.02;
    if (ns > self.baseScale) { ns = self.baseScale; }     // 不超过用户/中控设的上限
    NSInteger nb = (NSInteger)(self.adaptBitrateBps * 1.15);
    if (nb > self.baseBitrateBps) { nb = self.baseBitrateBps; }
    if (fabs(ns - self.adaptScale) < 0.001 && nb == self.adaptBitrateBps) {
        self.goodStreak = 0;
        return;
    }
    self.adaptScale = ns;
    self.adaptBitrateBps = nb;
    self.goodStreak = 0;
    [self applyAdaptiveValues];
    NSLog(@"[adapt] 网络恢复 → 升档 scale=%.2f bitrate=%ld", ns, (long)nb);
}

- (void)startStatTimer {
    if (self.statTimer) { return; }
    __weak typeof(self) weakSelf = self;
    self.statTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) { [t invalidate]; return; }
        [s pollStats];
    }];
    NSLog(@"[adapt] 已启动自适应（每 2s 采样丢包/时延）");
}

#pragma mark - 推帧

- (void)pushPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!self.videoSource || !pixelBuffer) { return; }

    // 抓屏层可能随时改出图尺寸（在线改档位），尺寸变了就重算一次输出格式
    NSInteger pw = (NSInteger)CVPixelBufferGetWidth(pixelBuffer);
    NSInteger ph = (NSInteger)CVPixelBufferGetHeight(pixelBuffer);
    if (self.sourceWidth != pw || self.sourceHeight != ph) {
        self.sourceWidth = pw;
        self.sourceHeight = ph;
        [self applyOutputFormat];
        NSLog(@"[rtc] 输入尺寸变成 %ldx%ld", (long)pw, (long)ph);
    }

    // 设备转身：输出宽高要跟着换（否则就是“只显示一半”），这里发现象限变了就重算
    int q = [AkunOrientation quad];
    if (q != self.appliedQuad) {
        [self applyOutputFormat];
        NSLog(@"[rtc] 象限 %d -> %d，重算输出尺寸", self.appliedQuad, q);
    }

    RTCCVPixelBuffer *buffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    int64_t ns = (int64_t)(CACurrentMediaTime() * 1000000000.0);
    // 设备转了就随帧带旋转信息：libwebrtc 会把画面转成对应方向再编码，
    // 接收端自然看到横屏画面（和 AKUN 的 OrientationSync 一个效果）
    RTCVideoRotation rot = RTCVideoRotation_0;
    switch ([AkunOrientation quad]) {
    case 1: rot = RTCVideoRotation_90; break;
    case 2: rot = RTCVideoRotation_180; break;
    case 3: rot = RTCVideoRotation_270; break;
    default: rot = RTCVideoRotation_0; break;
    }
    RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:buffer
                                                        rotation:rot
                                                     timeStampNs:ns];
    [self.videoSource capturer:self.capturer didCaptureVideoFrame:frame];

    self.pushedFrames++;
    if (self.pushedFrames % 150 == 0) {
        NSLog(@"[rtc] 已推 %lu 帧（源 %zux%zu）", (unsigned long)self.pushedFrames,
              CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
    }
}

- (void)stop {
    [self.statTimer invalidate];
    self.statTimer = nil;
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