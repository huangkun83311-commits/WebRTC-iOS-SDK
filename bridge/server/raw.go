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
	txt     chan string
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

// pushInfo 推送编码参数（手机晚于观看端上线时用）
func (rs *rawSub) pushInfo(fmtp string) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if rs.closed {
		return
	}
	select {
	case rs.txt <- `{"type":"info","fmtp":` + jsonString(fmtp) + `}`:
	default:
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

	rs := &rawSub{conn: conn, ch: make(chan []byte, 256), txt: make(chan string, 8)}
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

	// 写：二进制下发 RTP，文本下发控制（编码参数变化等）；单协程写，避免并发写 panic
	go func() {
		for {
			select {
			case b, ok := <-rs.ch:
				if !ok {
					return
				}
				_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
				if err := conn.WriteMessage(websocket.BinaryMessage, b); err != nil {
					return
				}
			case s, ok := <-rs.txt:
				if !ok {
					return
				}
				_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
				if err := conn.WriteMessage(websocket.TextMessage, []byte(s)); err != nil {
					return
					}
			}
		}
	}()

	// 保活：画面对端在有空闲的时候一个上行字节都不会发，光靠读超时会每 60 秒
	// 把自己踢一次（页面上就是灯红一下）。这里补 15 秒一次 ping，浏览器自动回 pong。
	stopPing := make(chan struct{})
	go func() {
		tk := time.NewTicker(15 * time.Second)
		defer tk.Stop()
		for {
			select {
			case <-tk.C:
				if err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(2*time.Second)); err != nil {
					return
				}
			case <-stopPing:
				return
			}
		}
	}()
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(90 * time.Second))
	})

	// 读：只接受控制消息（要关键帧、心跳）
	for {
		_ = conn.SetReadDeadline(time.Now().Add(90 * time.Second))
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

	close(stopPing)
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

// dispatchRaw 供 main.go 分流用。
// 注意：SFU 的房间名是 "video-<id>"（手机推流建的就是这个房间），直绘端必须落到同一个房间，
// 否则拿到的永远是空房间（第一次接线时踩过：日志里 codec= 空、一帧不下发）。
func (s *sfu) dispatchRaw(w http.ResponseWriter, r *http.Request, roomWithPrefix string) {
	id := strings.TrimPrefix(roomWithPrefix, "rtp-")
	s.handleRaw(w, r, "video-"+id)
}
