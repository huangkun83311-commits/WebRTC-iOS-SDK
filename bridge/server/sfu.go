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
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
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
}

type sfu struct {
	mu    sync.RWMutex
	rooms map[string]*sfuRoom
}

func newSFU() *sfu { return &sfu{rooms: make(map[string]*sfuRoom)} }

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

func newPeer() (*webrtc.PeerConnection, error) {
	se := webrtc.SettingEngine{}
	// 局域网场景：host candidate 直连即可，账号不发 mDNS，避免某些端解析不到 .local。
	se.SetICEMulticastDNSMode(0) // 0 = disabled
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
	p := &sfuPeer{room: room, role: role, conn: conn}
	rm := s.room(room)

	pc, err := newPeer()
	if err != nil {
		log.Printf("sfu pc: %v", err)
		_ = conn.Close()
		return
	}
	p.pc = pc

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		j := c.ToJSON()
		_ = p.sendJSON(map[string]interface{}{
			"type":          "candidate",
			"candidate":     j.Candidate,
			"sdpMid":        j.SDPMid,
			"sdpMLineIndex": j.SDPMLineIndex,
		})
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
				go func(sender *webrtc.RTPSender) {
					// 观看端的 RTCP（NACK/PLI）丢弃；丢包重传由浏览器侧 NACK 就地处理。
					buf := make([]byte, 1500)
					for {
						if _, _, err := sender.Read(buf); err != nil {
							return
						}
					}
				}(rs)
				vw = &viewer{peer: p, track: track, pt: prof.payloadType}
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
			_ = p.sendJSON(map[string]interface{}{"type": "answer", "sdp": pc.LocalDescription().SDP})
			log.Printf("sfu room=%s role=%s 已回 answer", room, role)
			// 新观看端进来后，让手机立刻吐一个关键帧，避免等下一个自然 I 帧。
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
			}
		case "answer":
			if role == "publisher" {
				if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: msg.Sdp}); err != nil {
					log.Printf("sfu room=%s 设置手机 answer 失败: %v", room, err)
				} else {
					log.Printf("sfu room=%s 手机已接受收流协商", room)
				}
			}
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
