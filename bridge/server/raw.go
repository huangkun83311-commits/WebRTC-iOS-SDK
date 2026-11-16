// raw.go —— 「低延迟直绘」通道：把手机的 H264 RTP 原样通过 WebSocket 推给浏览器，
// 浏览器用 WebCodecs 解码后直接画到 canvas，绕开 <video> 的 jitter buffer 与合成队列。
//
// 为什么需要它：实测浏览器接收端 jitterBufferDelay 稳定在 33~62ms（Chrome 视频通道的地板），
// 而设备侧抓屏只有 15ms，编码 6ms —— 感官延迟的大头其实在浏览器自己排队。VNC 客户端是
// 原生 canvas 直绘所以跟手，这条路就是把浏览器拉回到同一个量级。
// WebRTC 链路（视为 P2P/SFU 那套）仍然保留，本通道只负责"把已编码的帧尽早送到屏幕上"。
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/rtcp"
)

// rawSub 一个「直绘」订阅者
type rawSub struct {
	conn    *websocket.Conn
	ch      chan []byte
	dropped uint64
	mu      sync.Mutex
	closed  bool
}

func (rs *rawSub) close() {
	rs.mu.Lock()
	if rs.closed {
		rs.mu.Unlock()
		return
	}
	rs.closed = true
	rs.mu.Unlock()
	_ = rs.conn.Close()
}

// push 非阻塞投递：慢客户端丢最旧的包，绝不允许拖慢手机那一侧
func (rs *rawSub) push(b []byte) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if rs.closed {
		return
	}
	select {
	case rs.ch <- b:
	default:
		// 缓冲满：丢一包，由页面按序号缺口请求关键帧
		rs.dropped++
	}
}

func (s *sfu) requestKeyframe(rm *sfuRoom) {
	rm.mu.RLock()
	pub := rm.pub
	ssrc := rm.pubSSRC
	rm.mu.RUnlock()
	if pub != nil && pub.pc != nil {
		_ = pub.pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}})
		log.Printf("sfu room=%s 直绘端请求关键帧 ssrc=%d", rm.name, ssrc)
	}
}

// handleRaw 处理 /ws?room=rtp-<id>&role=raw
func (s *sfu) handleRaw(w http.ResponseWriter, r *http.Request, room string) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("raw upgrade failed: %v", err)
		return
	}
	rm := s.room(room)

	rs := &rawSub{conn: conn, ch: make(chan []byte, 256)}
	rm.mu.Lock()
	rm.raws = append(rm.raws, rs)
	info := rm.h264Info
	rm.mu.Unlock()

	log.Printf("sfu room=%s 直绘端加入（共 %d 个）codec=%s", room, len(rm.rawsOrNil()), info)

	// 先把编码参数发过去，页面据此 configure WebCodecs
	if info != "" {
		_ = conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"info","fmtp":`+jsonString(info)+`}`))
	} else {
		_ = conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"info","fmtp":""}`))
	}

	// 写：把 RTP 包原样下发
	go func() {
		for b := range rs.ch {
			_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
			if err := conn.WriteMessage(websocket.BinaryMessage, b); err != nil {
				return
			}
		}
	}()

	// 读：只接受控制消息（要关键帧、心跳）
	for {
		_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		mt, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		if mt != websocket.TextMessage {
			continue
		}
		var m struct {
			T string `json:"t"`
		}
		if err := json.Unmarshal(data, &m); err != nil {
			continue
		}
		if m.T == "keyframe" {
			s.requestKeyframe(rm)
		}
	}

	rs.close()
	rm.mu.Lock()
	for i, v := range rm.raws {
		if v == rs {
			rm.raws = append(rm.raws[:i], rm.raws[i+1:]...)
			break
		}
	}
	rm.mu.Unlock()
	log.Printf("sfu room=%s 直绘端离开，丢弃包数=%d", room, rs.dropped)
}

func (rm *sfuRoom) rawsOrNil() []*rawSub {
	rm.mu.RLock()
	defer rm.mu.RUnlock()
	return rm.raws
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// dispatchRaw 供 main.go 分流用
func (s *sfu) dispatchRaw(w http.ResponseWriter, r *http.Request, roomWithPrefix string) {
	s.handleRaw(w, r, strings.TrimPrefix(roomWithPrefix, "rtp-"))
}
