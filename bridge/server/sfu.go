// SFU：视频房间由服务器自身终结两端 WebRTC。
//
// 为什么要这样做：原来 video-<id> 房间只是"广播"信令，两个观看端同时进房时，
// 手机对每个观看端各建一条 PeerConnection、各编码一路 30fps H264（A11 上每路 6~7ms），
// 而且 offer/answer 会被广播到错误的对端，导致画面冻结。
// 改成 SFU 后：手机只推一路给服务器（编码一次），服务器把 RTP 原样转发给任意多个观看端，
// 手机 CPU 与人数无关，上行也只有一路。
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/ice/v4"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

// h264Profile 描述一个观看端 SDP 里协商出来的 H264 参数。
type h264Profile struct {
	payloadType uint8
	fmtp        string
}

// parseH264FromSDP 从 SDP 文本里取 H264 的 payload type 与 fmtp（视频 m 行的首选编码）。
func parseH264FromSDP(sdp string) (h264Profile, bool) {
	rtpmap := map[string]string{}
	fmtp := map[string]string{}
	for _, raw := range strings.Split(sdp, "\n") {
		ln := strings.TrimSpace(raw)
		if strings.HasPrefix(ln, "a=rtpmap:") {
			body := strings.TrimPrefix(ln, "a=rtpmap:")
			if sp := strings.Index(body, " "); sp > 0 {
				rtpmap[body[:sp]] = body[sp+1:]
			}
		} else if strings.HasPrefix(ln, "a=fmtp:") {
			body := strings.TrimPrefix(ln, "a=fmtp:")
			if sp := strings.Index(body, " "); sp > 0 {
				fmtp[body[:sp]] = body[sp+1:]
			}
		}
	}
	// 优先找 m=video 行里第一个 H264 的 payload type。
	videoLine := ""
	for _, raw := range strings.Split(sdp, "\n") {
		ln := strings.TrimSpace(raw)
		if strings.HasPrefix(ln, "m=video") {
			videoLine = ln
			break
		}
	}
	if videoLine == "" {
		return h264Profile{}, false
	}
	var pt string
	for _, f := range strings.Fields(videoLine)[3:] {
		if strings.HasPrefix(rtpmap[f], "H264") {
			pt = f
			break
		}
	}
	if pt == "" {
		return h264Profile{}, false
	}
	var n uint8
	if _, err := fmt.Sscanf(pt, "%d", &n); err != nil {
		return h264Profile{}, false
	}
	return h264Profile{payloadType: n, fmtp: fmtp[pt]}, true
}

type sfuPeer struct {
	room string
	role string
	conn *websocket.Conn
	pc   *webrtc.PeerConnection

	outMu sync.Mutex // 保护 conn 写

	// 候选缓存：ICE 的 trickle 候选往往在 answer 之前就产生，此时对端还没
	// SetRemoteDescription，直接发过去会被对端丢弃（pion/浏览器都报
	// remote description is not set），于是公网候选永远进不去、画面黑屏。
	// 做法：answer 之前先攒着，answer 发出去之后再按顺序补发。
	candMu   sync.Mutex
	candSent bool
	candBuf  []map[string]interface{}

	lan bool // 该连接是否局域网直连（决定发内网候选还是公网候选）
}

// hostIsLAN 判断这次请求是不是来自局域网（直连 8080 / 经反代但 Host 是内网地址）。
// 用途：内网观看端不要把公网 6900 候选也发给他（绕大圈、RTT 从 0 变 50ms+）；
// 外网观看端不要把 192.168.x / 169.254 / IPv6 候选发给他（浏览器会先试这些死地址，
// 白等几秒才回退公网候选 —— 外网首帧 3 秒就是这么来的）。
func hostIsLAN(hostport string) bool {
	h := hostport
	if i := strings.LastIndex(hostport, ":"); i > 0 {
		h = hostport[:i]
	}
	ip := net.ParseIP(strings.Trim(h, "[]"))
	if ip == nil {
		// 域名（本机测试/反代）按局域网处理
		return true
	}
	return ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast()
}

// isLANAddr 单个候选地址是否属于"只有局域网才能通"的那类。
func isLANAddr(addr string) bool {
	ip := net.ParseIP(addr)
	if ip == nil {
		return false
	}
	if ip.To4() == nil {
		return true // IPv6：frp 没映射，外网用不到
	}
	return ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast()
}

// rewriteSDPForPublic 外网访问时重写 answer SDP：删掉所有内网/链路本地/IPv6 候选，
// 换成唯一一条公网映射候选。只过滤 trickle 是不够的 —— 候选同时写在 SDP 里，
// 浏览器会优先用 SDP 里的死地址，白等几秒才回退，这就是外网首帧慢的原因。
func rewriteSDPForPublic(sdp, pubIP string, pubPort int) string {
	lines := strings.Split(sdp, "\n")
	out := make([]string, 0, len(lines)+1)
	added := false
	for _, ln := range lines {
		trimmed := strings.TrimSuffix(ln, "\r")
		if strings.HasPrefix(trimmed, "a=candidate:") {
			f := strings.Fields(trimmed)
			// a=candidate:<foundation> <component> <proto> <prio> <addr> <port> typ host ...
			if len(f) >= 6 && isLANAddr(f[4]) {
				continue
			}
			out = append(out, ln)
			continue
		}
		out = append(out, ln)
		if !added && strings.HasPrefix(trimmed, "a=ice-ufrag:") {
			out = append(out, fmt.Sprintf("a=candidate:99 1 udp 2130706431 %s %d typ host generation 0", pubIP, pubPort))
			added = true
		}
	}
	return strings.Join(out, "\n")
}

// sendCand 发送一条 ICE 候选；answer 发出前先缓存，避免对端还没 remote description。
func (p *sfuPeer) sendCand(m map[string]interface{}) {
	p.candMu.Lock()
	if !p.candSent {
		p.candBuf = append(p.candBuf, m)
		p.candMu.Unlock()
		return
	}
	p.candMu.Unlock()
	_ = p.sendJSON(m)
}

// flushCand 在 answer 之后调用：把攒下的候选一次性补发，并切成直发模式。
func (p *sfuPeer) flushCand() {
	p.candMu.Lock()
	p.candSent = true
	buf := p.candBuf
	p.candBuf = nil
	p.candMu.Unlock()
	for _, m := range buf {
		_ = p.sendJSON(m)
	}
}

func (p *sfuPeer) sendJSON(v interface{}) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	p.outMu.Lock()
	defer p.outMu.Unlock()
	_ = p.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return p.conn.WriteMessage(websocket.TextMessage, b)
}

// viewer 是挂在房间上的一个观看端。
type viewer struct {
	peer     *sfuPeer
	track    *webrtc.TrackLocalStaticRTP
	pt       uint8
	packets  atomic.Uint64
	lastSeen atomic.Int64
	lastPli  atomic.Int64 // 浏览器 PLI 限流，避免每帧都喊手机
}

// rtpCache 房间级重传缓存。
// 关键：服务端只是转发，浏览器丢包后会发 NACK 请求重传；以前这里把观看端 RTCP 直接丢弃，
// 丢掉的包永远补不回来 —— 浏览器只能干等下一个关键帧，外网"冻 13.9 秒"就是这么来的。
// 现在把最近 600 个包留在内存里，NACK 来了就地补发（每个观看端按自己的 payload type 改写）。
type rtpCache struct {
	mu    sync.Mutex
	m     map[uint16]*rtp.Packet
	order []uint16
}

func (c *rtpCache) put(p *rtp.Packet) {
	cp := *p
	cp.Payload = append([]byte(nil), p.Payload...)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m == nil {
		c.m = make(map[uint16]*rtp.Packet, 640)
	}
	if _, ok := c.m[p.SequenceNumber]; ok {
		return
	}
	c.m[p.SequenceNumber] = &cp
	c.order = append(c.order, p.SequenceNumber)
	if len(c.order) > 600 {
		old := c.order[0]
		c.order = c.order[1:]
		delete(c.m, old)
	}
}

func (c *rtpCache) get(seq uint16) *rtp.Packet {
	c.mu.Lock()
	defer c.mu.Unlock()
	p := c.m[seq]
	if p == nil {
		return nil
	}
	cp := *p
	cp.Payload = append([]byte(nil), p.Payload...)
	return &cp
}

type sfuRoom struct {
	name    string
	mu      sync.RWMutex
	pub     *sfuPeer
	pubSSRC uint32
	readers []*viewer
	raws    []*rawSub     // 直绘（WebCodecs）订阅者
	h264Info string       // 手机的 H264 fmtp，给直绘端 configure 用
	lastLog time.Time
	sent    atomic.Uint64
	cache   rtpCache
}

type sfu struct {
	mu    sync.RWMutex
	rooms map[string]*sfuRoom
}

// onNeedFrame 让「有人要看」这件事直接传回手机：新观看端进来、或手机重新推流上来时，
// 手机立刻吐一帧（画面静止时它平时 2 秒才保活一帧，这就是首屏黑 1~2 秒的真凶）。
var onNeedFrame func(deviceID string)

func newSFU() *sfu { return &sfu{rooms: make(map[string]*sfuRoom)} }

// kickFrame 通知对应设备的控制通道「马上出一帧」。
func kickFrame(room string) {
	if onNeedFrame == nil {
		return
	}
	id := strings.TrimPrefix(room, "video-")
	if id == "" || id == room {
		return
	}
	go onNeedFrame(id)
}

func (s *sfu) room(name string) *sfuRoom {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.rooms[name]
	if !ok {
		r = &sfuRoom{name: name}
		s.rooms[name] = r
	}
	return r
}

func (s *sfu) drop(name string, r *sfuRoom) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if cur, ok := s.rooms[name]; ok && cur == r {
		delete(s.rooms, name)
	}
}

// mediaEngine 声明服务器能收/能发哪些编码。手机端是 libwebrtc，首选 H264（硬编），
// 这里同时注册 profile-level-id=42e01f 与 42001f 两种基线，避免 fmtp 不匹配导致协商失败。
func newMediaEngine() *webrtc.MediaEngine {
	me := &webrtc.MediaEngine{}
	codecs := []webrtc.RTPCodecParameters{
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH264,
				ClockRate:    90000,
				SDPFmtpLine:  "profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1",
				RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}},
			},
			PayloadType: 102,
		},
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH264,
				ClockRate:    90000,
				SDPFmtpLine:  "profile-level-id=42001f;level-asymmetry-allowed=1;packetization-mode=1",
				RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}},
			},
			PayloadType: 108,
		},
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeVP8,
				ClockRate:    90000,
				RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}},
			},
			PayloadType: 96,
		},
	}
	_ = me.RegisterCodec(codecs[0], webrtc.RTPCodecTypeVideo)
	_ = me.RegisterCodec(codecs[1], webrtc.RTPCodecTypeVideo)
	_ = me.RegisterCodec(codecs[2], webrtc.RTPCodecTypeVideo)
	return me
}

var (
	// iceUDPMux 把服务器所有 peer 的 ICE UDP 收发包固定到一个端口，
	// 这样外网可以用一条 frp udp 映射（106.52.43.129:6900 -> 本机 6900）承载媒体。
	iceUDPMux  ice.UDPMux
	iceUDPPort int
	// icePublicIP 是那条映射在公网上的地址，会作为额外 host candidate 播给浏览器。
	icePublicIP string
)

// initICE 在启动时调用：固定 ICE UDP 端口（0=不固定，保持原来随机端口的局域网行为）。
func initICE(udpPort int, publicIP string) {
	icePublicIP = publicIP
	if udpPort <= 0 {
		return
	}
	// 绑 0.0.0.0 而不是 127.0.0.1：局域网观看端仍要能用 192.168.x.x:6900 直连，
	// 绑回环会把局域网这条路掐死。
	conn, err := net.ListenPacket("udp4", fmt.Sprintf("0.0.0.0:%d", udpPort))
	if err != nil {
		log.Printf("[ice] 绑定 UDP %d 失败: %v", udpPort, err)
		return
	}
	iceUDPMux = ice.NewUDPMuxDefault(ice.UDPMuxParams{UDPConn: conn})
	iceUDPPort = udpPort
	log.Printf("[ice] ICE UDP 固定端口 %d，公网播报 %s", udpPort, publicIP)
}

func newPeer() (*webrtc.PeerConnection, error) {
	se := webrtc.SettingEngine{}
	// 局域网场景：host candidate 直连即可，账号不发 mDNS，避免某些端解析不到 .local。
	se.SetICEMulticastDNSMode(0) // 0 = disabled
	if iceUDPMux != nil {
		se.SetICEUDPMux(iceUDPMux)
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(newMediaEngine()), webrtc.WithSettingEngine(se))
	return api.NewPeerConnection(webrtc.Configuration{})
}

// handleSFU 处理 video-<id> 房间的 ws 连接（publisher=手机，viewer=浏览器）。
func (s *sfu) handleSFU(w http.ResponseWriter, r *http.Request, room, role string) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("sfu upgrade failed: %v", err)
		return
	}
	lanAccess := hostIsLAN(r.Host)
	p := &sfuPeer{room: room, role: role, conn: conn, lan: lanAccess}
	rm := s.room(room)

	pc, err := newPeer()
	if err != nil {
		log.Printf("sfu pc: %v", err)
		_ = conn.Close()
		return
	}
	p.pc = pc

	publicCandSent := false
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		j := c.ToJSON()
		// 按访问来源只发"真能通"的那一类候选：
		// 外网访问 → 只留 IPv4 公网侧（内网/169.254/IPv6 一律不发，避免浏览器白等）；
		// 内网访问 → 只留内网，别把公网绕行候选塞给局域网用户。
		if !p.lan && c.Address != "" && isLANAddr(c.Address) {
			return
		}
		p.sendCand(map[string]interface{}{
			"type":          "candidate",
			"candidate":     j.Candidate,
			"sdpMid":        j.SDPMid,
			"sdpMLineIndex": j.SDPMLineIndex,
		})
		// 额外补一条"公网映射"候选：只有当 ICE UDP 固定端口 + 公网 IP 都配了才发。
		// 浏览器同时拿到内网 192.168.x.x:6900 和公网 106.52.43.129:6900，谁通走谁。
		if !p.lan && icePublicIP != "" && iceUDPPort > 0 && !publicCandSent {
			publicCandSent = true
			p.sendCand(map[string]interface{}{
				"type":          "candidate",
				"candidate":     fmt.Sprintf("candidate:99 1 udp 2130706431 %s %d typ host", icePublicIP, iceUDPPort),
				"sdpMid":        j.SDPMid,
				"sdpMLineIndex": j.SDPMLineIndex,
			})
			log.Printf("[ice] 已补发公网候选 %s:%d", icePublicIP, iceUDPPort)
		}
	})

	var vw *viewer
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		log.Printf("sfu room=%s role=%s pc=%s", room, role, st.String())
		if st == webrtc.PeerConnectionStateFailed || st == webrtc.PeerConnectionStateClosed {
			_ = conn.Close()
		}
	})

	pc.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if role != "publisher" {
			return
		}
		log.Printf("sfu room=%s 收到手机视频流 codec=%s pt=%d ssrc=%d fmtp=%s", room, track.Codec().MimeType, track.PayloadType(), track.SSRC(), track.Codec().SDPFmtpLine)
		rm.mu.Lock()
		rm.pubSSRC = uint32(track.SSRC())
		rm.h264Info = track.Codec().SDPFmtpLine
		rm.mu.Unlock()
		var last *rtp.Packet
		for {
			pkt, _, err := track.ReadRTP()
			if err != nil {
				return
			}
			if last == nil || last.SequenceNumber != pkt.SequenceNumber {
				last = pkt
			}
			rm.mu.RLock()
			targets := rm.readers
			raws := rm.raws
			nowT := time.Now()
			doLog := (len(targets) > 0 || len(raws) > 0) && nowT.Sub(rm.lastLog) > 2*time.Second
			if doLog {
				rm.lastLog = nowT
			}
			rm.mu.RUnlock()
			// 直绘端：H264 RTP 原样下发，由浏览器 WebCodecs 解码直绘（跳过 jitter buffer）
			if len(raws) > 0 {
				if raw, err := pkt.Marshal(); err == nil {
					for _, rs := range raws {
						rs.push(raw)
					}
				}
			}
			if len(targets) > 0 {
				rm.cache.put(pkt)
			}
			for _, v := range targets {
				out := *pkt
				// 每个观看端协商出的 payload type 可能不同，逐端改写。
				out.PayloadType = v.pt
				out.Payload = append([]byte(nil), pkt.Payload...)
				if err := v.track.WriteRTP(&out); err == nil {
					v.packets.Add(1)
					rm.sent.Add(1)
				}
			}
			if doLog {
				rm.mu.RLock()
				for _, v := range rm.readers {
					log.Printf("sfu room=%s 转发统计 pkt=%d", room, v.packets.Load())
				}
				rm.mu.RUnlock()
			}
		}
	})

	// 注册
	switch role {
	case "publisher":
		rm.mu.Lock()
		if rm.pub != nil {
			old := rm.pub
			rm.pub = nil
			_ = old.conn.Close()
		}
		rm.pub = p
		waiting := len(rm.readers)
		rm.mu.Unlock()
		if waiting > 0 {
			log.Printf("sfu room=%s 手机接入时已有 %d 个观看端在等，稍后按需索帧", room, waiting)
		}
		// 手机端是"应答方"：它不会自己发 offer，必须由服务器主动发起收流协商。
		go func() {
			if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo,
				webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
				log.Printf("sfu room=%s 加收流通道失败: %v", room, err)
				return
			}
			offer, err := pc.CreateOffer(nil)
			if err != nil {
				log.Printf("sfu room=%s 生成 offer 失败: %v", room, err)
				return
			}
			gather := webrtc.GatheringCompletePromise(pc)
			if err := pc.SetLocalDescription(offer); err != nil {
				log.Printf("sfu room=%s 设置 offer 失败: %v", room, err)
				return
			}
			<-gather
			_ = p.sendJSON(map[string]interface{}{"type": "offer", "sdp": pc.LocalDescription().SDP})
			log.Printf("sfu room=%s 已向手机发 offer（收流）", room)
		}()
	case "viewer":
	default:
		_ = conn.Close()
		return
	}

	cleanup := func() {
		rm.mu.Lock()
		if role == "publisher" && rm.pub == p {
			rm.pub = nil
		}
		if vw != nil {
			for i, v := range rm.readers {
				if v == vw {
					rm.readers = append(rm.readers[:i], rm.readers[i+1:]...)
					break
				}
			}
			_ = vw.track
		}
		empty := rm.pub == nil && len(rm.readers) == 0
		rm.mu.Unlock()
		if empty {
			s.drop(room, rm)
		}
		_ = pc.Close()
		_ = conn.Close()
		log.Printf("sfu leave room=%s role=%s", room, role)
	}
	defer cleanup()

	conn.SetReadLimit(1 << 20)
	_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	})
	go func() {
		t := time.NewTicker(20 * time.Second)
		defer t.Stop()
		for range t.C {
			p.outMu.Lock()
			_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			err := conn.WriteMessage(websocket.PingMessage, nil)
			p.outMu.Unlock()
			if err != nil {
				return
			}
		}
	}()

	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return
		}
		_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		var msg struct {
			Type          string `json:"type"`
			Sdp           string `json:"sdp"`
			Candidate     string `json:"candidate"`
			SdpMid        string `json:"sdpMid"`
			SdpMLineIndex int    `json:"sdpMLineIndex"`
		}
		if err := json.Unmarshal(payload, &msg); err != nil {
			continue
		}

		switch msg.Type {
		case "offer":
			desc := webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: msg.Sdp}
			if role == "viewer" {
				// 给这个观看端建一条发送轨：payload type 与 fmtp 必须和它自己 offer 里的一致，
				// 否则 answer 里的编码对不上，浏览器会直接丢包不出画面。
				prof, ok := parseH264FromSDP(msg.Sdp)
				if !ok {
					log.Printf("sfu room=%s 观看端未提供 H264，退回默认 102", room)
					prof = h264Profile{payloadType: 102, fmtp: "profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1"}
				}
				codec := webrtc.RTPCodecCapability{
					MimeType:     webrtc.MimeTypeH264,
					ClockRate:    90000,
					SDPFmtpLine:  prof.fmtp,
					RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}},
				}
				track, err := webrtc.NewTrackLocalStaticRTP(codec, "video", "akun-sfu")
				if err != nil {
					log.Printf("sfu track: %v", err)
					return
				}
				rs, err := pc.AddTrack(track)
				if err != nil {
					log.Printf("sfu addtrack: %v", err)
					return
				}
				vw = &viewer{peer: p, track: track, pt: prof.payloadType}
				// 观看端 RTCP：NACK 从房间缓存就地补发，PLI 转给手机要关键帧。
				go func(sender *webrtc.RTPSender, v *viewer) {
					buf := make([]byte, 2048)
					for {
						n, _, err := sender.Read(buf)
						if err != nil {
							return
						}
						pkts, err := rtcp.Unmarshal(buf[:n])
						if err != nil {
							continue
						}
						for _, pk := range pkts {
							switch x := pk.(type) {
							case *rtcp.TransportLayerNack:
								var nacked, sent int
								for _, pair := range x.Nacks {
									for _, seq := range pair.PacketList() {
										rp := rm.cache.get(seq)
										if rp == nil {
											nacked++
											continue
										}
										out := *rp
										out.PayloadType = v.pt
										if err := v.track.WriteRTP(&out); err == nil {
											sent++
										}
									}
								}
								if sent > 0 && time.Now().UnixNano()-v.lastPli.Load() > int64(2*time.Second) {
									log.Printf("sfu room=%s 补发重传 %d 包（缓存未命中 %d）", room, sent, nacked)
								}
							case *rtcp.PictureLossIndication:
								// 浏览器自己发现画面卡了 → 立刻转给手机（限流 500ms 一次）
								if time.Now().UnixNano()-v.lastPli.Load() > int64(500*time.Millisecond) {
									v.lastPli.Store(time.Now().UnixNano())
									rm.mu.RLock()
									pub2 := rm.pub
									ssrc2 := rm.pubSSRC
									rm.mu.RUnlock()
									if pub2 != nil && pub2.pc != nil {
										_ = pub2.pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc2}})
									}
									kickFrame(room)
									log.Printf("sfu room=%s 观看端PLI→已向手机要关键帧", room)
								}
							}
						}
					}
				}(rs, vw)
				rm.mu.Lock()
				rm.readers = append(rm.readers, vw)
				rm.mu.Unlock()
				log.Printf("sfu room=%s 观看端加入（共 %d 个）pt=%d", room, len(rm.readers), prof.payloadType)
			}
			if err := pc.SetRemoteDescription(desc); err != nil {
				log.Printf("sfu room=%s role=%s setRemote: %v", room, role, err)
				return
			}
			answer, err := pc.CreateAnswer(nil)
			if err != nil {
				log.Printf("sfu room=%s answer: %v", room, err)
				return
			}
			gather := webrtc.GatheringCompletePromise(pc)
			if err := pc.SetLocalDescription(answer); err != nil {
				log.Printf("sfu room=%s setLocal: %v", room, err)
				return
			}
			<-gather
			answerSDP := pc.LocalDescription().SDP
			if !p.lan && icePublicIP != "" && iceUDPPort > 0 {
				answerSDP = rewriteSDPForPublic(answerSDP, icePublicIP, iceUDPPort)
				log.Printf("sfu room=%s 外网观看端：answer 只保留公网候选 %s:%d", room, icePublicIP, iceUDPPort)
			}
			_ = p.sendJSON(map[string]interface{}{"type": "answer", "sdp": answerSDP})
			// answer 已发，对端可以 SetRemoteDescription 了，这时候补发攒下的候选。
			p.flushCand()
			log.Printf("sfu room=%s role=%s 已回 answer", room, role)
			// 新观看端进来后：① RTCP PLI 要一个关键帧；② 直接喊手机抓一帧 ——
			// 只发 PLI 是不够的，编码器要等「下一帧输入」才吐 IDR，静止画面下那帧要等 2 秒保活。
			if role == "viewer" {
				rm.mu.RLock()
				pub := rm.pub
				rm.mu.RUnlock()
				if pub != nil && pub.pc != nil {
					rm.mu.RLock()
					ssrc := rm.pubSSRC
					rm.mu.RUnlock()
					_ = pub.pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}})
					log.Printf("sfu room=%s 已向手机请求关键帧 ssrc=%d", room, ssrc)
				}
				kickFrame(room)
				log.Printf("sfu room=%s 已通知手机立刻出帧（首屏不等保活）", room)
			}
		case "answer":
			if role == "publisher" {
				if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: msg.Sdp}); err != nil {
					log.Printf("sfu room=%s 设置手机 answer 失败: %v", room, err)
				} else {
					log.Printf("sfu room=%s 手机已接受收流协商", room)
				}
			}
		case "keyframe":
			// 观看端自己发现卡住了（或刚唤醒）→ 要一次关键帧，同时喊手机立刻抓一帧。
			s.requestKeyframe(rm)
			kickFrame(room)
		case "candidate":
			idx := uint16(msg.SdpMLineIndex)
			_ = pc.AddICECandidate(webrtc.ICECandidateInit{
				Candidate:     msg.Candidate,
				SDPMid:        &msg.SdpMid,
				SDPMLineIndex: &idx,
			})
		}
	}
}

// handleSFUHTTP 是 HTTP 入口，供 main 里的 mux 使用。
func (s *sfu) handleSFUHTTP(w http.ResponseWriter, r *http.Request, room, role string) {
	s.handleSFU(w, r, room, role)
}
