//
//  SampleHandler.swift
//  ScreenShare（ReplayKit 广播上传扩展）
//
//  把手机整屏用 ReplayKit 抓下来，直接编码成 WebRTC 视频流，通过自建信令
//  （/ws?room=video-<设备ID>&role=publisher）推给浏览器。
//
//  为什么不再用 AntMediaClient：
//    它只会说 Ant Media 的私有 WS 协议（/WebRTCAppEE/websocket），自建信令对接不上。
//    这里直接用 WebRTC.xcframework 的原生 PeerConnection，协议换成通用
//    offer/answer/candidate：浏览器发 recvonly offer，本端应答并挂上视频轨。
//
//  类名保持 SampleHandler 不变，Info.plist 的 NSExtensionPrincipalClass 无需改动。
//

import ReplayKit
import WebRTC
import UIKit
import os.log

class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - 配置（静态缓存，避免自定义 init）

    private static let configCache: [String: String] = SampleHandler.loadConfig()

    private var signalBase: String { SampleHandler.configCache["base"] ?? "" }
    private var deviceId: String { SampleHandler.configCache["deviceId"] ?? "dev001" }
    private var turnURL: String? { SampleHandler.configCache["turnURL"] }
    private var turnUser: String? { SampleHandler.configCache["turnUser"] }
    private var turnPassword: String? { SampleHandler.configCache["turnPass"] }

    // MARK: - WebRTC

    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource!
    private var videoTrack: RTCVideoTrack!
    private var videoCapturer: RTCVideoCapturer!
    private var pendingCandidates: [RTCIceCandidate] = []
    private var remoteDescriptionSet = false

    // MARK: - 信令

    private var ws: URLSessionWebSocketTask?
    private var reconnectAttempt = 0

    private let logger = OSLog(subsystem: "com.akun.bridge.screenshare", category: "screen")

    // MARK: - 配置读取

    /// 优先级：App Group > 扩展自身 Info.plist。
    /// 自签 / 巨魔环境 App Group 容器通常不可用，此时靠 Info.plist 兜底。
    private static func loadConfig() -> [String: String] {
        var out: [String: String] = [:]

        if let shared = UserDefaults(suiteName: "group.io.antmedia.ios.webrtc-sample") {
            out["base"] = shared.string(forKey: "url")
            out["deviceId"] = shared.string(forKey: "streamId")
            out["turnURL"] = shared.string(forKey: "turnURL")
            out["turnUser"] = shared.string(forKey: "turnUser")
            out["turnPass"] = shared.string(forKey: "turnPassword")
        }

        if let info = Bundle.main.infoDictionary {
            if out["base"] == nil, let v = info["WebRTCServerURL"] as? String { out["base"] = v }
            if out["deviceId"] == nil, let v = info["WebRTCStreamId"] as? String { out["deviceId"] = v }
            if out["turnURL"] == nil, let v = info["WebRTCTurnURL"] as? String { out["turnURL"] = v }
            if out["turnUser"] == nil, let v = info["WebRTCTurnUser"] as? String { out["turnUser"] = v }
            if out["turnPass"] == nil, let v = info["WebRTCTurnPassword"] as? String { out["turnPass"] = v }
        }

        return out.compactMapValues { $0.isEmpty ? nil : $0 }
    }

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard !signalBase.isEmpty else {
            finishBroadcastWithError(NSError(domain: "ScreenShare", code: -2,
                userInfo: [NSLocalizedFailureReasonErrorKey: "未配置信令地址 WebRTCServerURL"]))
            return
        }

        setupWebRTC()
        setupSignaling()
    }

    override func broadcastFinished() {
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        peerConnection?.close()
        peerConnection = nil
    }

    // MARK: - WebRTC

    private func setupWebRTC() {
        RTCInitializeSSL()

        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)

        videoSource = factory.videoSource(forScreenCast: true)
        videoSource.adaptOutputFormat(toWidth: 720, height: 1280, fps: 30)

        videoCapturer = RTCVideoCapturer()
        videoTrack = factory.videoTrack(with: videoSource, trackId: "screen0")

        var iceServers: [RTCIceServer] = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        if let turnURL = turnURL, !turnURL.isEmpty {
            iceServers.append(RTCIceServer(urlStrings: [turnURL], username: turnUser, credential: turnPassword))
        }

        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        peerConnection?.add(videoTrack, streamIds: ["screen"])
    }

    // MARK: - 信令

    private var signalingURL: URL? {
        var base = signalBase
        if base.hasPrefix("http://") { base = "ws://" + base.dropFirst("http://".count) }
        if base.hasPrefix("https://") { base = "wss://" + base.dropFirst("https://".count) }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/ws?room=video-\(deviceId)&role=publisher")
    }

    private func setupSignaling() {
        guard let url = signalingURL else { return }

        let task = URLSession(configuration: .default).webSocketTask(with: url)
        ws = task
        task.resume()

        receiveLoop(on: task)
        schedulePing(on: task)
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                os_log("ws receive error: \(error.localizedDescription, privacy: .public)", log: self.logger, type: .error)
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleSignal(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handleSignal(text) }
                @unknown default:
                    break
                }
                self.receiveLoop(on: task)
            }
        }
    }

    private func schedulePing(on task: URLSessionWebSocketTask) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self, weak task] in
            guard let self = self, let task = task, self.ws === task else { return }
            task.sendPing { error in
                if let error = error {
                    os_log("ws ping failed: \(error.localizedDescription, privacy: .public)", log: self.logger, type: .error)
                    self.scheduleReconnect()
                } else {
                    self.reconnectAttempt = 0
                    self.schedulePing(on: task)
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.ws?.cancel(with: .goingAway, reason: nil)
            self?.setupSignaling()
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        ws?.send(.string(text)) { error in
            if let error = error {
                os_log("ws send failed: \(error.localizedDescription, privacy: .public)", log: .default, type: .error)
            }
        }
    }

    private func handleSignal(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "offer":
            guard let sdp = obj["sdp"] as? String, let pc = peerConnection else { return }
            let offer = RTCSessionDescription(type: .offer, sdp: sdp)

            pc.setRemoteDescription(offer) { [weak self] error in
                guard let self = self, error == nil, let pc = self.peerConnection else { return }
                self.remoteDescriptionSet = true
                self.attachTrackToTransceiver()

                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                pc.answer(for: constraints) { answer, err in
                    guard let answer = answer, err == nil else { return }
                    pc.setLocalDescription(answer) { e in
                        guard e == nil else { return }
                        self.send(["type": "answer", "sdp": answer.sdp])
                        self.flushCandidates()
                    }
                }
            }

        case "candidate":
            guard let sdp = obj["candidate"] as? String, let pc = peerConnection else { return }
            let candidate = RTCIceCandidate(sdp: sdp,
                                            sdpMLineIndex: Int32(obj["sdpMLineIndex"] as? Int ?? 0),
                                            sdpMid: obj["sdpMid"] as? String)
            if remoteDescriptionSet {
                pc.add(candidate) { _ in }
            } else {
                pendingCandidates.append(candidate)
            }

        case "_peerJoined":
            os_log("viewer joined", log: logger, type: .info)

        default:
            break
        }
    }

    private func flushCandidates() {
        guard let pc = peerConnection else { return }
        for c in pendingCandidates { pc.add(c) { _ in } }
        pendingCandidates.removeAll()
    }

    /// 浏览器发的是 recvonly offer，本地必须把视频轨挂到对应 video sender 上，
    /// 否则 answer 里没有 sendonly 的 m-line，浏览器收不到任何画面。
    private func attachTrackToTransceiver() {
        guard let pc = peerConnection, let track = videoTrack else { return }
        for transceiver in pc.transceivers where transceiver.mediaType == .video {
            transceiver.sender.track = track
            return
        }
    }

    // MARK: - 采样

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ns = Int64(DispatchTime.now().uptimeNanoseconds)
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: ns)

        videoSource.capturer(videoCapturer, didCapture: frame)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension SampleHandler: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // 浏览器是唯一的 offerer，本端不主动协商，避免双方互发 offer。
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        os_log("ice state: \(newState.rawValue, privacy: .public)", log: logger, type: .info)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        send(["type": "candidate",
              "candidate": candidate.sdp,
              "sdpMid": candidate.sdpMid ?? "",
              "sdpMLineIndex": Int(candidate.sdpMLineIndex)])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
