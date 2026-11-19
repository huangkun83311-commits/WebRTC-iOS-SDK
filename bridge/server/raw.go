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
	"sync/atomic"
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

	// waitIDRUntil：重放关键帧之后，到这个时刻为止先不收实时 P 帧（0 表示不等待）。
	// 重放里只有 SPS/PPS/IDR，实时 P 帧参考的是中间那些被跳过的帧，直接发下去浏览器只会花屏；
	// 画面先停在重放出来的那张静止帧上，等手机吐出新 IDR 再干净接上。超时兜底防止一直定格。
	waitIDRUntil atomic.Int64
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

// pushWait 可等待投递：给 GOP 重放这种「一包都不能丢」的场景用。
// 正常实时转发仍然走非阻塞 push，绝不拖慢手机那一侧。
func (rs *rawSub) pushWait(b []byte, d time.Duration) bool {
	rs.mu.Lock()
	if rs.closed {
		rs.mu.Unlock()
		return false
	}
	ch := rs.ch
	rs.mu.Unlock()
	select {
	case ch <- b:
		return true
	case <-time.After(d):
		return false
	}
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
func (rs *rawSub) pushInfo(fmtp, mime string) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if rs.closed {
		return
	}
	// codec 必须一起下发：直绘端要按实际编码（H264/vp8）选择 WebCodecs 的 configure，
	// 且 VP8 的 RTP 载荷不是 NALU，解析方式完全不同。
	select {
	case rs.txt <- `{"type":"info","fmtp":` + jsonString(fmtp) + `,"codec":` + jsonString(mime) + `}`:
	default:
	}
}

func (s *sfu) requestKeyframe(rm *sfuRoom) {
	rm.mu.RLock()
	pub := rm.pub
	ssrc := rm.pubSSRC
	rm.mu.RUnlock()
	if pub != nil && pub.pc != nil {
		if !rm.claimKeyRequest() {
			return
		}
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

	rs := &rawSub{conn: conn, ch: make(chan []byte, 1024), txt: make(chan string, 8)}
	rm.mu.Lock()
	rm.raws = append(rm.raws, rs)
	info := rm.h264Info
	mime := rm.videoMime
	rm.mu.Unlock()

	log.Printf("sfu room=%s 直绘端加入（共 %d 个）codec=%s fmtp=%s", room, len(rm.rawsOrNil()), mime, info)

	// 先把编码参数发过去，页面据此 configure WebCodecs。
	// VP8 没有 fmtp（info 为空），但 codec 字段必须给，否则页面会按 H264/NALU 去解析 VP8 载荷。
	_ = conn.WriteMessage(websocket.TextMessage,
		[]byte(`{"type":"info","fmtp":`+jsonString(info)+`,"codec":`+jsonString(mime)+`}`))

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

	// 新直绘端不重放历史关键帧，直接向手机要一个新的 IDR。这里踩过两个坑，记在这别再走回去：
	//  1) 重放缓存里几秒前的旧 IDR：那一帧能立刻显示（页面「闪一下」就出画），但紧接着的实时
	//     P 帧参考的是手机最新的那个 IDR，不是这个旧的，参考帧对不上，解出来就是黑 ——
	//     现象正是「刷新闪一下然后一直黑」。
	//  2) 重放之后再「等新 IDR、期间不转发实时帧」：那 1.5 秒会在 RTP 序号上留下几百个包的
	//     空洞，页面判定序号断裂后清空分片，正好把新 IDR 的前半截切掉，同样黑。
	// 所以现在只请求 IDR，然后按实时流顺序原样转发；页面侧有「等 IDR」门控，
	// 中间的 P 帧不进解码器，IDR 一到就是干净画面，序号也完全连续。
	// 这里不能再用 mime 判断：实测自动重连上来的观看端 query 里没有 codec 参数，mime 为空，
	// 判断为 false 就不请求 IDR；而页面侧又处在「只接受关键帧」的等待状态，
	// 结果就是干等手机自己吐 IDR，画面一直黑（另一个带 codec 的窗口却正常）。
	// 所以无条件请求，mime 仅用于日志。
	log.Printf("sfu room=%s 新直绘端加入，请求新 IDR（不重放历史关键帧）codec=%q", room, mime)
	s.requestKeyframe(rm)

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
