// SFU：视频房间由服务器自身终结两端 WebRTC。
//
// 为什么要这样做：原来 video-<id> 房间只是"广播"信令，两个观看端同时进房时，
// 手机对每个观看端各建一条 PeerConnection、各编码一路 30fps H264（A11 上每路 6~7ms），
// 而且 offer/answer 会被广播到错误的对端，导致画面冻结。
// 改成 SFU 后：手机只推一路给服务器（编码一次），服务器把 RTP 原样转发给任意多个观看端，
// 手机 CPU 与人数无关，上行也只有一路。
package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
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
// parseVideoProfileFromSDP 按编码名（H264 / VP8）在 SDP 里找对应的 payload type。
// SFU 是纯转发，手机的编码不一定是 H264，写死 H264 会让观看端把 VP8 当 H264 解，一帧都出不来。
func parseVideoProfileFromSDP(sdp, mime string) (h264Profile, bool) {
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
		if strings.HasPrefix(rtpmap[f], mime) {
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

func parseH264FromSDP(sdp string) (h264Profile, bool) {
	return parseVideoProfileFromSDP(sdp, "H264")
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
	// 回环地址不算局域网：xtcp/frp 的 visitor 就是把远端变成本机 127.0.0.1，
	// 若按局域网处理，服务端只播 192.168.x.x 候选，客户根本连不到 -> pc=failed。
	if ip.IsLoopback() {
		return false
	}
	return ip.IsPrivate() || ip.IsLinkLocalUnicast()
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
// 保留公网可达的候选，并按优先级插入两条兜底：
//
//	srflx  —— 运营商 NAT 上的真实映射，两端直连（媒体不经 frp，延迟/流量都最省）
//	relay  —— frp 映射（106.52.43.129:6900），打洞失败时才回落
//
// 优先级：srflx 1694498815 > relay 16777215，浏览器会先试直连。
// 只过滤 trickle 是不够的 —— 候选同时写在 SDP 里，浏览器会优先用 SDP 里的死地址。
func rewriteSDPForPublic(sdp, pubIP string, pubPort int) string {
	sip, sport := getSrflx()
	lines := strings.Split(sdp, "\n")
	out := make([]string, 0, len(lines)+2)
	added := false
	for _, ln := range lines {
		trimmed := strings.TrimSuffix(ln, "\r")
		if strings.HasPrefix(trimmed, "a=candidate:") {
			f := strings.Fields(trimmed)
			// a=candidate:<foundation> <component> <proto> <prio> <addr> <port> typ host ...
			if len(f) >= 6 && isLANAddr(f[4]) {
				continue
			}
			// 已经是我们手搓的 srflx/relay，跳过（下面统一插）
			if strings.Contains(trimmed, "typ srflx") || strings.Contains(trimmed, "typ relay") {
				continue
			}
			out = append(out, ln)
			continue
		}
		out = append(out, ln)
		if !added && strings.HasPrefix(trimmed, "a=ice-ufrag:") {
			if sip != "" && sport > 0 {
				out = append(out, fmt.Sprintf("a=candidate:98 1 udp 1694498815 %s %d typ srflx raddr 0.0.0.0 rport 0 generation 0", sip, sport))
			}
			if relayCandidate && pubIP != "" && pubPort > 0 {
				out = append(out, fmt.Sprintf("a=candidate:99 1 udp 2130706431 %s %d typ host generation 0", pubIP, pubPort))
			}
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
	pt       atomic.Int32 // 发给浏览器的 payload type，必须等于 answer 里实际声明的那个
	mime     string       // 该观看端协商的视频编码（跟随手机，H264 或 VP8）
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
	name      string
	mu        sync.RWMutex
	pub       *sfuPeer
	pubSSRC   uint32
	readers   []*viewer
	raws      []*rawSub // 直绘（WebCodecs）订阅者
	h264Info  string    // 手机的 H264 fmtp，给直绘端 configure 用
	videoMime string    // 手机实际推的编码（H264/VP8），SFU 是透传，观看端必须按它协商，不能写死 H264
	lastLog   time.Time
	sent      atomic.Uint64
	cache     rtpCache

	// ---- 最近 GOP 缓存（首屏加速）----
	// 新观看端/直绘端加入时，手机要等下一次输入才吐 IDR，实测首屏要 1.1~1.4 秒。
	// 这里常驻一小段「从最新 IDR 起」的连续 RTP 包，新端一连上就原样重放，
	// 立刻能解出画面；随后实时流从这段的末尾无缝接上（seq 本来就是连续的）。
	gopMu    sync.Mutex
	gop      []*rtp.Packet
	gopBytes int
	gopAt    time.Time
	keyDone  bool // 关键帧段已封闭，后面的 P 帧不再进缓存

	// 关键帧请求节流（直绘端的 PLI 也走这里，避免一次连接连发好几次）
	keyMu      sync.Mutex
	lastKeyReq time.Time
}

// claimKeyRequest 给「本房间向手机要关键帧」加 600ms 节流。
// 一次页面连接会从好几个入口同时触发（WS open 的 rawAskKey、SFU 的 PLI、页面的 keyframe 消息），
// 每次都让手机重吐一个 IDR：既浪费码率，也打断正常编码节奏，画面上看就是"卡一下"。
func (rm *sfuRoom) claimKeyRequest() bool {
	rm.keyMu.Lock()
	defer rm.keyMu.Unlock()
	if time.Since(rm.lastKeyReq) < 600*time.Millisecond {
		return false
	}
	rm.lastKeyReq = time.Now()
	return true
}

// GOP 缓存上限：够装一个完整 GOP（高动态 30fps、2 秒一个 IDR 约 60 帧 ≈ 900 包），
// 同时防止静止/异常情况下无限增长。超限从头部丢最老的包，保留最新的一段。
const (
	gopMaxPkts  = 3000
	gopMaxBytes = 4 << 20 // 4MB
)

// h264IsGopStart 判断这个包是不是「一个新 GOP 的开头」：
// SPS(7) 一定出现在 IDR 之前；有的编码器不重发 SPS，那就认单包 IDR(5) 或 FU-A 的 IDR 起始分片。
func h264IsGopStart(p *rtp.Packet) bool {
	if len(p.Payload) == 0 {
		return false
	}
	t := p.Payload[0] & 0x1f
	switch t {
	case 7: // SPS
		return true
	case 5: // 单包承载整个 IDR slice
		return true
	case 24: // STAP-A 聚合包，一般带 SPS/PPS
		return true
	case 28: // FU-A 分片：只看起始分片（S 位=1），且分片内类型是 IDR 或 SPS
		if len(p.Payload) < 2 || p.Payload[1]&0x80 == 0 {
			return false
		}
		nt := p.Payload[1] & 0x1f
		return nt == 5 || nt == 7
	}
	return false
}

// h264IsKeySeg 判断这个包是否属于「关键帧段」（SPS / PPS / SEI / IDR）。
// 返回 false 表示已经进到 P/B 帧的 slice —— 关键帧段到此结束。
//
// 为什么要区分：首屏只需要 IDR 本身（解出来就是一张完整画面）。
// 把整个 GOP 都缓存下来再重放，等于让新打开的页面把几百个历史帧「快进」播一遍 ——
// 实测就是刷新时画面飞快地冲过去，而不是直接就位显示当前画面。
func h264IsKeySeg(p *rtp.Packet) bool {
	if len(p.Payload) == 0 {
		return false
	}
	switch p.Payload[0] & 0x1f {
	case 1: // 非 IDR 的 slice（P/B 帧）
		return false
	case 28: // FU-A：真实 NAL 类型在 payload[1] 的低 5 位
		if len(p.Payload) < 2 {
			return false
		}
		return p.Payload[1]&0x1f != 1
	}
	return true
}

// gopPut 把包攒进「最近的关键帧段」。同一时间戳内的包都算这一帧，不会重复开新段。
func (rm *sfuRoom) gopPut(p *rtp.Packet) {
	rm.gopMu.Lock()
	defer rm.gopMu.Unlock()

	lastTs := uint32(0)
	if n := len(rm.gop); n > 0 {
		lastTs = rm.gop[n-1].Timestamp
	}
	if h264IsGopStart(p) && (len(rm.gop) == 0 || lastTs != p.Timestamp) {
		rm.gop = rm.gop[:0]
		rm.gopBytes = 0
		rm.gopAt = time.Now()
		rm.keyDone = false
	} else if len(rm.gop) == 0 {
		// 还没见过 GOP 起点：不缓存半截流（从 P 帧起的一段解不出，重放反而更慢）
		return
	}
	// 注意：上面判定「开新 GOP」之后必须继续往下，把这个包本身也存进去。
	// 之前这里错写成「重置完直接 return」，导致 GOP 首包（SPS/IDR）被丢掉，缓存永远是空的 ——
	// 表现就是日志里从来没出现过「重放最近 GOP」。
	if rm.keyDone {
		return
	}
	if !h264IsKeySeg(p) {
		rm.keyDone = true // 关键帧段结束，后面的 P 帧不再进缓存
		return
	}
	cp := *p
	cp.Payload = append([]byte(nil), p.Payload...)
	rm.gop = append(rm.gop, &cp)
	rm.gopBytes += len(cp.Payload)
	for len(rm.gop) > 1 && (len(rm.gop) > gopMaxPkts || rm.gopBytes > gopMaxBytes) {
		rm.gopBytes -= len(rm.gop[0].Payload)
		rm.gop = rm.gop[1:]
	}
}

// gopSnapshot 取一份当前 GOP 的快照（调用方持有的是副本，可以放心慢慢写）。
func (rm *sfuRoom) gopSnapshot() []*rtp.Packet {
	rm.gopMu.Lock()
	defer rm.gopMu.Unlock()
	if len(rm.gop) == 0 || !h264IsGopStart(rm.gop[0]) {
		// 头部被截断过、已经不是从 IDR 开始，重放出去也解不出，交给 kickFrame 要新 IDR
		return nil
	}
	return rm.gop
}

// replayGopToViewer 把缓存 GOP 重放给新加入的 WebRTC 观看端。返回补发包数与总包数。
func (rm *sfuRoom) replayGopToViewer(v *viewer) (int, int) {
	pkts := rm.gopSnapshot()
	if len(pkts) == 0 {
		return 0, 0
	}
	sent := 0
	for _, p := range pkts {
		out := *p
		out.PayloadType = uint8(v.pt.Load())
		out.Payload = append([]byte(nil), p.Payload...)
		if err := v.track.WriteRTP(&out); err == nil {
			sent++
			v.packets.Add(1)
			rm.sent.Add(1)
		}
	}
	return sent, len(pkts)
}

// replayGopToRaw 把缓存 GOP 重放给新加入的直绘端。
// 这里用「可等待」投递而不是非阻塞 push：重放是首屏的最后一环，丢一包就可能整段解不出来，
// 宁可慢一点也不能丢。写协程卡住（2 秒还塞不进去）就中止，交给 kickFrame 走新 IDR。
func (rm *sfuRoom) replayGopToRaw(rs *rawSub) (int, int) {
	pkts := rm.gopSnapshot()
	if len(pkts) == 0 {
		return 0, 0
	}
	sent := 0
	for _, p := range pkts {
		b, err := p.Marshal()
		if err != nil {
			continue
		}
		if !rs.pushWait(b, 2*time.Second) {
			break
		}
		sent++
	}
	return sent, len(pkts)
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
//
// 加了房间级节流：页面刚连上时会连续触发好几次（SFU 的 PLI、raw 的 requestKeyframe、
// 页面的 keyframe 消息），实测一次连接能连发 4 次 —— 每次都会让手机重新吐一个 IDR，
// 既浪费码率也打断正常编码节奏。600ms 内的重复请求合并成一次。
var (
	kickMu   sync.Mutex
	kickLast = map[string]time.Time{}
)

func kickFrame(room string) {
	if onNeedFrame == nil {
		return
	}
	id := strings.TrimPrefix(room, "video-")
	if id == "" || id == room {
		return
	}
	kickMu.Lock()
	if t, ok := kickLast[room]; ok && time.Since(t) < 600*time.Millisecond {
		kickMu.Unlock()
		return
	}
	kickLast[room] = time.Now()
	kickMu.Unlock()
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

// mediaEngine 声明服务器能收/能发哪些编码。只注册 H264（42e01f / 42001f 两种基线，
// 避免 fmtp 不匹配导致协商失败），不注册 VP8 —— 见下方注释，VP8 会让手机走软编且与直绘链路不兼容。
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
			// iOS 的 RTCDefaultVideoEncoderFactory 默认提供 Constrained High 640c1f
			// （kRTCMaxSupportedH264ProfileLevelConstrainedHigh）与 Constrained Baseline 42e01f，
			// VideoToolbox 对 High profile 硬编支持最好。offer 里少了 640c1f，
			// 手机找不到匹配 profile 就拿不到编码器，只能退到 VP8 软编。
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH264,
				ClockRate:    90000,
				SDPFmtpLine:  "profile-level-id=640c1f;level-asymmetry-allowed=1;packetization-mode=1",
				RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}},
			},
			PayloadType: 106,
		},
		{
			// iOS 的 RTCDefaultVideoEncoderFactory 在真机上打印出来的实际值是 640c33 / 42e033
			// （Constrained High 5.1 / Constrained Baseline 5.1），level 是 0x33=51。
			// 这是手机自己 supportedCodecs 里最优先的两项，offer 里必须原样给出，
			// 否则 iOS 匹配不到 encoder，只能退回 VP8 软编。
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH264,
				ClockRate:    90000,
				SDPFmtpLine:  "profile-level-id=640c33;level-asymmetry-allowed=1;packetization-mode=1",
				RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}},
			},
			PayloadType: 105,
		},
		{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH264,
				ClockRate:    90000,
				SDPFmtpLine:  "profile-level-id=42e033;level-asymmetry-allowed=1;packetization-mode=1",
				RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}},
			},
			PayloadType: 107,
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
	// 同时注册 iOS 真正支持的三个 H264 profile：42e01f(Constrained Baseline)、
	// 42001f(Baseline)、640c1f(Constrained High)。iOS 的 encoder factory 只要在 offer 里
	// 找到 supportedCodecs 中的任一项，就会创建 VideoToolbox 硬编码器；之前只给一个 profile，
	// 匹配失败就整条退到 VP8 软编——这才是"跑的不是 H264"的根因，不是设备没有 H264。
	// 注册顺序决定 offer 里 m=video 的排列，也就决定手机最终挑哪个 profile。
	// 把 640c33（Constrained High 5.1）放到最前面：High 支持 CABAC + 8x8 变换，
	// 同样码率下压缩效率比 Constrained Baseline(42e01f) 高 15~20% —— 这是画质能提升的
	// 唯一实质手段（VNC 是 16bpp 裸传，我们是有损编码，只能从编码效率里抠）。
	// 其余 profile 全部保留在后面，万一手机不接受 High 会自然回落到 baseline，不会没画面。
	_ = me.RegisterCodec(codecs[3], webrtc.RTPCodecTypeVideo) // 640c33 Constrained High 5.1
	_ = me.RegisterCodec(codecs[0], webrtc.RTPCodecTypeVideo) // 42e01f Constrained Baseline
	_ = me.RegisterCodec(codecs[4], webrtc.RTPCodecTypeVideo) // 42e033 Constrained Baseline 5.1
	_ = me.RegisterCodec(codecs[2], webrtc.RTPCodecTypeVideo) // 640c1f Constrained High
	_ = me.RegisterCodec(codecs[1], webrtc.RTPCodecTypeVideo) // 42001f Baseline
	// 故意不注册 VP8（codecs[5]）：offer 里只要有 VP8，iOS 的 answer 就偏好它，永远回软编。
	// 只给 H264 才能强制走 VideoToolbox 硬件编码。万一手机真拿不到编码器，日志立刻是
	// [adapt] 上行=0kbps 编码=-1ms，那时把下面这行打开即可回退。
	// _ = me.RegisterCodec(codecs[5], webrtc.RTPCodecTypeVideo)
	return me
}

var (
	// iceUDPMux 把服务器所有 peer 的 ICE UDP 收发包固定到一个端口，
	// 这样外网可以用一条 frp udp 映射（106.52.43.129:6900 -> 本机 6900）承载媒体。
	iceUDPMux  ice.UDPMux
	iceUDPPort int
	// icePublicIP 是 frp 映射在公网上的地址，作为 relay（中继）候选播给浏览器，兜底用。
	icePublicIP string
	// relayCandidate=true 才把 frp 中继候选一起发出去（-fallback 启动参数）。
	// 默认 false：纯打洞，一条中继都不发。
	relayCandidate bool
	// iceProbe 是包在 UDPMux 外面的一层连接：它自己吞掉 STUN 应答、顺手记下公网映射。
	iceProbe *stunProbeConn
	// srflx 是"本机 UDP 端口经运营商 NAT 之后的真实公网 IP:端口"，打洞直连就靠它。
	srflxMu   sync.Mutex
	srflxIP   string
	srflxPort int
)

// stunProbePool：能配合 frp/nathole 工作的 VoIP 类 STUN（支持 RFC3489 Change Request）。
// 实测（2026-11-16，本机移动宽带）：
//
//	stun.voip.aebc.com  EasyNAT/BehaviorNoChange 通
//	stun.voipraider.com EasyNAT/BehaviorNoChange 通
//	stun.epygi.com      EasyNAT/BehaviorNoChange 通
//	stun.voipcheap.com  EasyNAT/BehaviorNoChange 通
//
// 其余 8 条已关停。Google/Cloudflare 那类只回单地址的 STUN 对 frp 无效，别加回来。
var stunProbePool = []string{
	"stun.voip.aebc.com:3478",
	"stun.voipraider.com:3478",
	"stun.epygi.com:3478",
	"stun.voipcheap.com:3478",
}

// stunProbeConn 包一层 net.PacketConn：
// 必须在"同一个 socket"上发 STUN 才拿得到与媒体一致的那条 NAT 映射，
// 但又不能让 STUN 应答漏进 pion 的收包循环，所以在 ReadFrom 里就地吞掉。
type stunProbeConn struct {
	net.PacketConn
	rr int
}

// stunPoolAddrs 是 stunProbePool 解析后的 ip:port 集合，用来区分
// "真正 STUN 服务器的应答" 和 "自己发出去又被 frp UDP 隧道环回来的应答"。
var stunPoolAddrs sync.Map

func isStunPoolAddr(a net.Addr) bool {
	if a == nil {
		return false
	}
	_, ok := stunPoolAddrs.Load(a.String())
	return ok
}

func (c *stunProbeConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		n, addr, err := c.PacketConn.ReadFrom(p)
		if err != nil {
			return n, addr, err
		}
		// STUN Binding Success Response: type 0x0101 + magic cookie
		// 只认探针池里那几台 STUN 的应答。frp 的 UDP 代理会把自己发出去的
		// Binding Success 回环回来，若不过滤，srflx 会被写成 192.168.x.x:6900
		// / 106.52.43.129:6900 这类假映射，浏览器就拿这些死地址去连 -> pc=failed。
		if n >= 20 && p[0] == 0x01 && p[1] == 0x01 &&
			binary.BigEndian.Uint32(p[4:8]) == 0x2112A442 {
			// 解析出映射后仍然把包交还给 pion：ICE 的 Binding Success 必须
			// 让 pion 自己看到，否则 ICE 握手建不起来（实测：吞掉 -> pc 永远 connecting）。
			parseXorMapped(p[:n])
			return n, addr, nil
		}
		return n, addr, nil
	}
}

// probe 一次向候选池里所有 STUN 都发 binding request（每包 20 字节，成本可忽略）；
// 单台超时是常态（voip.aebc 时常不回），全发才拿得到第一条能用的映射。
// 应答在 ReadFrom 里被解析，只留最新那条（EasyNAT 的映射对同一 socket 是稳定的）。
func (c *stunProbeConn) probe() {
	for _, addr := range stunProbePool {
		dst, err := net.ResolveUDPAddr("udp4", addr)
		if err != nil {
			continue
		}
		pkt := make([]byte, 20)
		binary.BigEndian.PutUint16(pkt[0:2], 0x0001) // Binding Request
		binary.BigEndian.PutUint16(pkt[2:4], 0)
		binary.BigEndian.PutUint32(pkt[4:8], 0x2112A442)
		rand.Read(pkt[8:20])
		_, _ = c.PacketConn.WriteTo(pkt, dst)
	}
}

// parseXorMapped 解析 XOR-MAPPED-ADDRESS(0x0020)，写进全局 srflx。
func parseXorMapped(b []byte) {
	if len(b) < 20 {
		return
	}
	n := int(binary.BigEndian.Uint16(b[2:4]))
	if 20+n > len(b) {
		return
	}
	body := b[20 : 20+n]
	for i := 0; i+4 <= len(body); {
		t := binary.BigEndian.Uint16(body[i : i+2])
		l := int(binary.BigEndian.Uint16(body[i+2 : i+4]))
		if t == 0x0020 && l >= 8 && i+4+l <= len(body) && body[i+5] == 1 { // 只要 IPv4 族
			xport := int(binary.BigEndian.Uint16(body[i+6:i+8]) ^ 0x2112)
			ip := net.IPv4(body[i+8]^0x21, body[i+9]^0x12, body[i+10]^0xa4, body[i+11]^0x42)
			// 只认真正的公网映射：frp 的 UDP 隧道会把自己发出去的 Binding Success
			// 环回进来，里面写的是 192.168.x.x / 106.52.43.129:6900 这类假地址，
			// 一旦写进 srflx，浏览器就拿着死地址去连 -> 黑屏。
			if ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
				return
			}
			if icePublicIP != "" && ip.String() == icePublicIP && xport == iceUDPPort {
				return
			}
			srflxMu.Lock()
			changed := srflxIP != ip.String() || srflxPort != xport
			srflxIP, srflxPort = ip.String(), xport
			srflxMu.Unlock()
			if changed {
				log.Printf("[ice] srflx 公网映射 %s:%d（打洞直连用这条）", ip.String(), xport)
			}
			return
		}
		i += 4 + ((l+3)/4)*4
	}
}

// getSrflx 取当前 srflx（可能为空=还没探测到）。
func getSrflx() (string, int) {
	srflxMu.Lock()
	defer srflxMu.Unlock()
	return srflxIP, srflxPort
}

// ensureSrflx 在发 answer 前确保已有直连地址：没有就立刻探一次并等最多 timeout。
// 纯打洞模式没有兜底候选，srflx 拿不到就等于没得连，所以这里必须等一等。
func ensureSrflx(timeout time.Duration) (string, int) {
	if sip, sport := getSrflx(); sip != "" && sport > 0 {
		return sip, sport
	}
	if iceProbe == nil {
		return "", 0
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		iceProbe.probe()
		time.Sleep(250 * time.Millisecond)
		if sip, sport := getSrflx(); sip != "" && sport > 0 {
			return sip, sport
		}
	}
	sip, sport := getSrflx()
	return sip, sport
}

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
	for _, a := range stunProbePool {
		if ua, err := net.ResolveUDPAddr("udp4", a); err == nil {
			stunPoolAddrs.Store(ua.String(), true)
		}
	}
	iceProbe = &stunProbeConn{PacketConn: conn}
	iceUDPMux = ice.NewUDPMuxDefault(ice.UDPMuxParams{UDPConn: iceProbe})
	iceUDPPort = udpPort
	log.Printf("[ice] ICE UDP 固定端口 %d，frp 中继 %s:%d", udpPort, publicIP, udpPort)

	// 立刻探一次，并每 5 秒刷新（保持运营商 NAT 上的端口映射不过期）。
	// 前 5 秒每秒补一轮：启动瞬间第一条回包慢，别让首个观看端等。
	iceProbe.probe()
	go func() {
		for i := 0; i < 5; i++ {
			time.Sleep(time.Second)
			iceProbe.probe()
		}
		tk := time.NewTicker(5 * time.Second)
		defer tk.Stop()
		for range tk.C {
			iceProbe.probe()
		}
	}()
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
		// 纯打洞：只补发一条 srflx（运营商 NAT 上的真实映射）。
		// 与云控管理"直达模式"一致 —— 打不通就是打不通，不回落 frp。
		// 若启动时带了 -fallback，才额外补一条 frp 中继候选（ICE 会自动优选 srflx）。
		if !p.lan && !publicCandSent {
			sent := false
			if sip, sport := getSrflx(); sip != "" && sport > 0 {
				sent = true
				p.sendCand(map[string]interface{}{
					"type":          "candidate",
					"candidate":     fmt.Sprintf("candidate:98 1 udp 1694498815 %s %d typ srflx raddr 0.0.0.0 rport 0 generation 0", sip, sport),
					"sdpMid":        j.SDPMid,
					"sdpMLineIndex": j.SDPMLineIndex,
				})
				log.Printf("[ice] 直连候选 srflx %s:%d", sip, sport)
			}
			if relayCandidate && icePublicIP != "" && iceUDPPort > 0 {
				sent = true
				p.sendCand(map[string]interface{}{
					"type":          "candidate",
					"candidate":     fmt.Sprintf("candidate:99 1 udp 2130706431 %s %d typ host", icePublicIP, iceUDPPort),
					"sdpMid":        j.SDPMid,
					"sdpMLineIndex": j.SDPMLineIndex,
				})
				log.Printf("[ice] 中继候选 %s:%d", icePublicIP, iceUDPPort)
			}
			publicCandSent = sent
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
		rm.videoMime = track.Codec().MimeType
		raws0 := rm.raws
		rm.mu.Unlock()
		// 观看端可能比手机先连上，编码参数到了要补发给它们，否则 WebCodecs 用错 profile 直接解不出
		for _, rs := range raws0 {
			rs.pushInfo(track.Codec().SDPFmtpLine, track.Codec().MimeType)
		}
		isH264 := strings.Contains(strings.ToLower(rm.videoMime), "h264")
		var last *rtp.Packet
		var diagTs uint32
		diagPkts, diagMarkers := 0, 0
		diagFrames, diagMulti, diagPktSum := 0, 0, 0
		diagLast := time.Now()
		lastPeriodicKey := time.Now()
		diagReport := func() {
			if diagFrames == 0 {
				return
			}
			avg := float64(diagPktSum) / float64(diagFrames)
			log.Printf("sfu room=%s [帧结构] 帧=%d/窗口 多marker帧=%d 平均包/帧=%.1f（marker>1 说明一帧被拆成多个访问单元，页面会把每块当残帧解出黑）", room, diagFrames, diagMulti, avg)
			diagFrames, diagMulti, diagPktSum = 0, 0, 0
		}
		for {
			pkt, _, err := track.ReadRTP()
			if err != nil {
				return
			}
			if last == nil || last.SequenceNumber != pkt.SequenceNumber {
				last = pkt
			}
			// 诊断：按 RTP 时间戳统计「每帧多少包、打了几个 marker」。
			// 用途是判定手机端编码器到底怎么切帧：一帧多 slice 但只在末尾打一个 marker 是正常的；
			// 同一帧里打到 2 个以上 marker，就说明这一帧被拆成了多个访问单元，
			// 浏览器侧按 marker 组装出来的每一块都是残帧，解出来就是黑 —— 这正是「fps 30、画面全黑」的来源。
			// 只写日志，不影响转发。
			if pkt.Header.Timestamp != diagTs {
				if diagPkts > 0 {
					diagFrames++
					if diagMarkers > 1 {
						diagMulti++
					}
					diagPktSum += diagPkts
				}
				diagTs = pkt.Header.Timestamp
				diagPkts = 0
				diagMarkers = 0
			}
			diagPkts++
			if pkt.Header.Marker {
				diagMarkers++
			}
			rm.mu.RLock()
			targets := rm.readers
			raws := rm.raws
			nowT := time.Now()
			doLog := (len(targets) > 0 || len(raws) > 0) && nowT.Sub(rm.lastLog) > 10*time.Second
			if doLog {
				rm.lastLog = nowT
			}
			if nowT.Sub(diagLast) > 3*time.Second {
				diagLast = nowT
				diagReport()
			}
			rm.mu.RUnlock()
			// 只要有人在看，就每 2 秒向手机要一个新 IDR。
			// 这是接收端主动刷新画面的标准做法（WebRTC 的 PLI 周期重发、Moonlight/Sunshine 的
			// 强制关键帧间隔都是这个思路）：H264 是帧间预测，一旦某一帧参考错了，
			// 错误会一直留在画面上 —— 画面静止时编码器只发 skip 帧，根本不会重画，
			// 那块花屏就会永久卡住（实测桌面静止时每帧只推 200 字节、脏图 0ms）。
			// 定时拿 IDR 之后，任何坏块最多存活 2 秒。
			// 注意必须放在 RUnlock 之后：requestKeyframe 内部还要读 rm.mu，重入读锁会死锁。
			// v62 行为：不主动按期要 IDR，只在「新观看端加入」和「页面自救」时请求一次。
			// 页面侧已有 1.5 秒无新帧就自救的逻辑，够用；按期强制 IDR 会让编码器每隔两秒吐
			// 一个大帧，静止画面上表现为周期性码率脉动，用户会感觉「每两秒顿一下」。
			_ = lastPeriodicKey
			// 直绘端：H264 RTP 原样下发，由浏览器 WebCodecs 解码直绘（跳过 jitter buffer）
			if len(raws) > 0 {
				if raw, err := pkt.Marshal(); err == nil {
					gopStart := isH264 && h264IsGopStart(pkt)
					nowN := time.Now().UnixNano()
					for _, rs := range raws {
						// 刚重放过关键帧段的直绘端：先用重放出来的那张静止画面顶着，
						// 等手机的新 IDR 到了再收实时流 —— 否则 P 帧参考的中间帧被跳过，画面会花屏。
						// 超时兜底：万一手机没吐 IDR，宁可花一帧也不能一直定格。
						if dl := rs.waitIDRUntil.Load(); dl != 0 {
							if !gopStart && nowN < dl {
								continue
							}
							rs.waitIDRUntil.Store(0)
						}
						rs.push(raw)
					}
				}
			}
			// 只要手机在推就持续维护最近 GOP。不能只在「已经有人在看」时才缓存 ——
			// 那样第一个打开页面的人永远是空缓存，吃不到首屏加速，只有后来的人才有。
			if isH264 {
				rm.gopPut(pkt)
			}
			if len(targets) > 0 {
				rm.cache.put(pkt)
			}
			for _, v := range targets {
				out := *pkt
				// 每个观看端协商出的 payload type 可能不同，逐端改写。
				out.PayloadType = uint8(v.pt.Load())
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
				// SFU 只转发不转码：观看端的编码必须跟随手机实际推的那个，
				// 写死 H264 会把 VP8 码流当成 H264 交给浏览器，一帧都解不出来（黑屏但 kbps 有数）。
				rm.mu.RLock()
				vmime := rm.videoMime
				rm.mu.RUnlock()
				if vmime == "" {
					// 观看端常常比手机先连上，这时还不知道手机用什么。
					// 实测手机只能编 VP8，所以默认按 VP8 协商，手机接上后编码对得上。
					vmime = webrtc.MimeTypeVP8
				}
				mimeShort := strings.TrimPrefix(vmime, "video/")
				prof, ok := parseVideoProfileFromSDP(msg.Sdp, mimeShort)
				if !ok {
					log.Printf("sfu room=%s 观看端未提供 %s，退回默认 102", room, mimeShort)
					prof = h264Profile{payloadType: 102}
				}
				if mimeShort == "H264" && prof.fmtp == "" {
					prof.fmtp = "profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1"
				}
				codec := webrtc.RTPCodecCapability{
					MimeType:     vmime,
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
				vw = &viewer{peer: p, track: track, mime: mimeShort}
				log.Printf("sfu room=%s 观看端编码跟随手机 %s（offer pt=%d）", room, mimeShort, prof.payloadType)
				// 先用浏览器 offer 里解析到的 PT 占位，answer 定稿后再校正成真实值
				vw.pt.Store(int32(prof.payloadType))
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
										out.PayloadType = uint8(v.pt.Load())
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
				// 先把缓存的最近 GOP 整段重放给这个观看端：不用等手机出 IDR，首屏立刻能出画面。
				// 重放的是快照、seq 与手机实时流连续，重放完 append 进 readers，实时流从最新包无缝接上；
				// 万一中间差了几包，浏览器发 NACK，cache 里有就补。
				if n, tot := rm.replayGopToViewer(vw); n > 0 {
					log.Printf("sfu room=%s 新观看端重放最近 GOP %d/%d 包（首屏不等 IDR）", room, n, tot)
				} else {
					log.Printf("sfu room=%s 新观看端无 GOP 可重放（缓存空），改走 kickFrame 要 IDR", room)
				}
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
			if role == "viewer" && vw != nil {
				// 关键修复：offer 里浏览器声明的 H264 PT 和 pion 在 answer 里实际分配的 PT
				// 可能不是同一个值。以前照 offer 的 PT 往回写包，浏览器按 answer 只认自己的 PT，
				// 其余一律当未知负载丢弃 —— 表现就是"收到码流（kbps 有数）但一帧都解不出来"。
				if ap, ok := parseVideoProfileFromSDP(answerSDP, vw.mime); ok {
					before := vw.pt.Load()
					vw.pt.Store(int32(ap.payloadType))
					if int(before) != int(ap.payloadType) {
						log.Printf("sfu room=%s 观看端 PT 校正 offer=%d → answer=%d", room, before, ap.payloadType)
					} else {
						log.Printf("sfu room=%s 观看端 PT 一致=%d", room, ap.payloadType)
					}
				}
			}
			if !p.lan {
				// 纯打洞（对标云控管理"直达模式"）：只给直连地址，不给任何中继候选。
				sip, sport := ensureSrflx(3 * time.Second)
				if sip == "" || sport == 0 {
					log.Printf("sfu room=%s 纯打洞失败：STUN 没有回映射，本次不可能连上", room)
				} else {
					log.Printf("sfu room=%s 纯打洞：直连候选 srflx %s:%d", room, sip, sport)
				}
				answerSDP = rewriteSDPForPublic(answerSDP, icePublicIP, iceUDPPort)
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
