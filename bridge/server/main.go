// AKUN Device Bridge - 信令与指令中继服务器
//
// 职责只有两件事：
//  1. WebRTC 信令中继（SDP offer/answer、ICE candidate），本身不碰媒体流，纯 P2P；
//  2. 控制指令中继（手机端守护进程 <-> 浏览器），走 WebSocket 而不是 DataChannel，
//     因为控制流量只有几百字节/秒，WS 足够且能让手机端不必再维持第二条 PeerConnection。
//
// 房间规则：/ws?room=<name>&role=<role>，同房间内的其它连接会收到你发的每一条消息。
// 约定使用两个房间：video-<deviceID>（信令）和 ctrl-<deviceID>（指令）。
package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

//go:embed web
var webFS embed.FS

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// 手机端与浏览器都可能来自任意来源，这里放开；生产环境请按域名收紧。
	CheckOrigin: func(r *http.Request) bool { return true },
}

type client struct {
	conn *websocket.Conn
	room string
	role string
	mu   sync.Mutex
}

func (c *client) send(payload []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return c.conn.WriteMessage(websocket.TextMessage, payload)
}

type hub struct {
	mu    sync.RWMutex
	rooms map[string]map[*client]struct{}
	sfu   *sfu
	// 每个房间最近一次生效的画质档（授权档 / 中控档）：设备重连或换机时自动套用，
	// 不用每次人工重下参数。key 是设备房间名（dev001），value 是 cfg 报文。
	profiles map[string]map[string]interface{}
}

func newHub() *hub { return &hub{rooms: make(map[string]map[*client]struct{}), sfu: newSFU()} }

func (h *hub) join(c *client) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	set, ok := h.rooms[c.room]
	if !ok {
		set = make(map[*client]struct{})
		h.rooms[c.room] = set
	}
	set[c] = struct{}{}
	return len(set)
}

func (h *hub) leave(c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set, ok := h.rooms[c.room]; ok {
		delete(set, c)
		if len(set) == 0 {
			delete(h.rooms, c.room)
		}
	}
}

func (h *hub) peers(c *client) []*client {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]*client, 0, 4)
	for other := range h.rooms[c.room] {
		if other != c {
			out = append(out, other)
		}
	}
	return out
}

func (h *hub) broadcast(c *client, payload []byte) {
	for _, p := range h.peers(c) {
		if err := p.send(payload); err != nil {
			log.Printf("send to %s/%s failed: %v", p.room, p.role, err)
		}
	}
}

// notify 给房间里其它人发一条系统消息，用于双方感知对端上下线。
func (h *hub) notify(c *client, typ string) {
	payload, _ := json.Marshal(map[string]string{"type": typ, "role": c.role})
	h.broadcast(c, payload)
}

func (h *hub) handleWS(w http.ResponseWriter, r *http.Request) {
	room := r.URL.Query().Get("room")
	role := r.URL.Query().Get("role")
	if room == "" {
		http.Error(w, "room is required", http.StatusBadRequest)
		return
	}
	if role == "" {
		role = "anonymous"
	}
	// 视频房间走 SFU：手机只推一路，服务器转给所有观看端（原来广播信令会让多个观看端互相打死）。
	if strings.HasPrefix(room, "video-") && (role == "publisher" || role == "viewer") {
		h.sfu.handleSFU(w, r, room, role)
		return
	}
	// 直绘通道：rtp-<id>，H264 RTP 原样下发，页面用 WebCodecs 解码丢到 canvas
	if strings.HasPrefix(room, "rtp-") {
		h.sfu.dispatchRaw(w, r, room)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade failed: %v", err)
		return
	}

	c := &client{conn: conn, room: room, role: role}
	n := h.join(c)
	log.Printf("join room=%s role=%s peers=%d", room, role, n)
	h.notify(c, "_peerJoined")

	// 设备控制通道（ctrl-xxx）一连上就把它所在房间的档位套一遍：
	// 这样「授权档 / 中控档」在设备重连、换机、重启后都自动恢复，
	// 不需要人工再点一次参数，正是用户要的"授权时按档次下发、平常用插件默认"。
	if strings.HasPrefix(room, "ctrl-") {
		dev := strings.TrimPrefix(room, "ctrl-")
		h.mu.RLock()
		prof := h.profiles[dev]
		h.mu.RUnlock()
		if prof != nil {
			if payload, err := json.Marshal(prof); err == nil {
				if err := c.send(payload); err == nil {
					log.Printf("应用存档档位 room=%s %s", dev, payload)
				}
			}
		}
	}

	defer func() {
		h.leave(c)
		h.notify(c, "_peerLeft")
		_ = conn.Close()
		log.Printf("leave room=%s role=%s", room, role)
	}()

	// 心跳：手机端在后台容易被 NAT / 运营商掐连接，靠 ping 保活。
	conn.SetReadLimit(1 << 20)
	_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	})

	pingDone := make(chan struct{})
	go func() {
		ticker := time.NewTicker(20 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				c.mu.Lock()
				_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				err := conn.WriteMessage(websocket.PingMessage, nil)
				c.mu.Unlock()
				if err != nil {
					return
				}
			case <-pingDone:
				return
			}
		}
	}()
	defer close(pingDone)

	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("read error room=%s role=%s: %v", room, role, err)
			}
			return
		}
		_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		logRelay(room, role, payload)
		h.broadcast(c, payload)
	}
}

// logRelay 打印一条转发的报文概要（只取 type 与长度），排障用。
func logRelay(room, role string, payload []byte) {
	var meta struct {
		Type      string `json:"type"`
		Candidate string `json:"candidate"`
		Sdp       string `json:"sdp"`
	}
	if err := json.Unmarshal(payload, &meta); err != nil {
		log.Printf("relay room=%s role=%s size=%d (非JSON)", room, role, len(payload))
		return
	}
	extra := ""
	if meta.Type == "candidate" && len(meta.Candidate) > 0 {
		if len(meta.Candidate) > 80 {
			extra = meta.Candidate[:80]
		} else {
			extra = meta.Candidate
		}
	} else if len(meta.Sdp) > 0 {
		extra = fmt.Sprintf("sdp=%d字节 %s", len(meta.Sdp), codecSummary(meta.Sdp))
	}
	log.Printf("relay room=%s role=%s type=%s size=%d %s", room, role, meta.Type, len(payload), extra)
}

// codecSummary 从 SDP 里扒出协商出的视频编码：m=video 行上的第一个 payload type，
// 再回查 rtpmap。排障时用来确认到底走的是 H264（硬编）还是 VP8（软编）。
func codecSummary(sdp string) string {
	rtpmap := map[string]string{}
	var firstPT string
	lines := strings.Split(sdp, "\n")
	for _, ln := range lines {
		ln = strings.TrimSpace(ln)
		if strings.HasPrefix(ln, "a=rtpmap:") {
			body := strings.TrimPrefix(ln, "a=rtpmap:")
			if sp := strings.Index(body, " "); sp > 0 {
				rtpmap[body[:sp]] = body[sp+1:]
			}
		}
	}
	for _, ln := range lines {
		ln = strings.TrimSpace(ln)
		if strings.HasPrefix(ln, "m=video") {
			fields := strings.Fields(ln)
			if len(fields) > 3 {
				firstPT = fields[3]
			}
			break
		}
	}
	if firstPT == "" {
		return ""
	}
	return fmt.Sprintf("video-pt=%s %s", firstPT, rtpmap[firstPT])
}

func (h *hub) handleRooms(w http.ResponseWriter, r *http.Request) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make(map[string]int, len(h.rooms))
	for name, set := range h.rooms {
		out[name] = len(set)
	}
	writeJSON(w, out)
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

// ---- 局域网自动发现：手机端不用手填 IP ----
//
// 手机广播一个探测包到 UDP 19951，本程序回自己的 http 地址。
// 回包里的 IP 用「朝对端 dial 一次取本地地址」的方式算出来，多网卡（有线/Wi-Fi/虚拟网卡）
// 时也能给出对的那一个。

func localIPToward(addr *net.UDPAddr) string {
	c, err := net.DialUDP("udp4", nil, addr)
	if err == nil {
		defer c.Close()
		if la, ok := c.LocalAddr().(*net.UDPAddr); ok && la.IP != nil && !la.IP.IsUnspecified() {
			return la.IP.String()
		}
	}
	return firstNonLoopbackIPv4()
}

func firstNonLoopbackIPv4() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "127.0.0.1"
	}
	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ip4 := ipnet.IP.To4(); ip4 != nil {
				return ip4.String()
			}
		}
	}
	return "127.0.0.1"
}

func startDiscovery(discoveryPort, httpPort int) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: discoveryPort})
	if err != nil {
		log.Printf("自动发现未启用（udp :%d 绑定失败）：%v", discoveryPort, err)
		return
	}
	log.Printf("自动发现监听 udp :%d，回包地址 http://<本机IP>:%d", discoveryPort, httpPort)

	go func() {
		buf := make([]byte, 512)
		for {
			n, addr, err := conn.ReadFromUDP(buf)
			if err != nil {
				log.Printf("discovery read: %v", err)
				return
			}
			if !bytes.Contains(buf[:n], []byte("AKUNBRIDGE")) {
				continue
			}
			localIP := localIPToward(addr)
			payload := fmt.Sprintf(`{"app":"akun-bridge","akun":true,"http":"http://%s:%d","port":%d}`,
				localIP, httpPort, httpPort)
			if _, err := conn.WriteToUDP([]byte(payload), addr); err != nil {
				log.Printf("discovery reply: %v", err)
				continue
			}
			log.Printf("自动发现：%s 探测，回 %s", addr, localIP)
		}
	}()
}

// httpPortFromAddr 把 ":8080" / "0.0.0.0:8080" 解析成 8080。
func httpPortFromAddr(addr string) int {
	idx := strings.LastIndex(addr, ":")
	if idx < 0 {
		return 8080
	}
	p, err := strconv.Atoi(addr[idx+1:])
	if err != nil {
		return 8080
	}
	return p
}

// roundKbps 只保留 10kbps 精度，避免把 1234.5678 这种数塞给前端
func roundKbps(v float64) int { return int(v/10) * 10 }

func main() {
	addr := flag.String("addr", ":8080", "监听地址，例如 :8080")
	discPort := flag.Int("disc", 19951, "UDP 自动发现端口，0 表示关闭")
	flag.Parse()

	h := newHub()
	h.profiles = map[string]map[string]interface{}{}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", h.handleWS)
	mux.HandleFunc("/api/rooms", h.handleRooms)
	// 设备端自动发现的身份校验：只有回出 app=akun-bridge 的地址才算我们的服务，
	// 避免把路由器管理页 / 别的 8080 服务当成信令端。
	mux.HandleFunc("/api/hello", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]interface{}{
			"app":     "akun-bridge",
			"http":    "http://" + r.Host,
			"disc":    *discPort,
			"version": "1.0.0",
		})
	})
	// 客户端侧指标落盘：网页每秒把 getStats 摘要 POST 上来，写成一行日志。
	// 这样「电脑这边到底收到什么（帧率/码率/丢包/缓冲/解码/点击延迟）」有据可查，
	// 不用靠人在页面上念数字；GET 拿回来就是这段日志的尾部。
	clientStatsPath := "clientstats.log"
	mux.HandleFunc("/api/client", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			truncate := func(b []byte) []byte {
				if len(b) > 60000 {
					return b[len(b)-60000:]
				}
				return b
			}
			b, err := os.ReadFile(clientStatsPath)
			if err != nil {
				w.Write([]byte("(还没有客户端数据)\n"))
				return
			}
			w.Write(truncate(b))
			return
		}
		body, _ := io.ReadAll(io.LimitReader(r.Body, 4096))
		line := time.Now().Format("2006-01-02 15:04:05") + " " + strings.TrimSpace(string(body)) + "\n"
		if f, err := os.OpenFile(clientStatsPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644); err == nil {
			f.WriteString(line)
			f.Close()
		}
		w.WriteHeader(http.StatusNoContent)
	})
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"status": "ok"})
	})
	// 在线调画质：/api/config?room=dev001&scale=0.35&fps=24&bitrate=3000000
	// 直接广播给控制通道，设备端即时生效，不用重装 deb（调延迟/清晰度用这个最快）。
	mux.HandleFunc("/api/config", func(w http.ResponseWriter, r *http.Request) {
		room := r.URL.Query().Get("room")
		if room == "" {
			room = "dev001"
		}
		msg := map[string]interface{}{"t": "cfg"}
		for _, k := range []string{"scale", "fps", "bitrate", "cap"} {
			if v := r.URL.Query().Get(k); v != "" {
				msg[k] = v
			}
		}
		payload, _ := json.Marshal(msg)
		target := "ctrl-" + room
		h.mu.RLock()
		set := h.rooms[target]
		h.mu.RUnlock()
		n := 0
		for c := range set {
			if err := c.send(payload); err == nil {
				n++
			}
		}
		// 记住这次生效的档位（合并而不是覆盖，方便分别改清晰度和上限）
		h.mu.Lock()
		if h.profiles[room] == nil {
			h.profiles[room] = map[string]interface{}{"t": "cfg"}
		}
		for k, v := range msg {
			h.profiles[room][k] = v
		}
		h.mu.Unlock()
		log.Printf("config room=%s sent=%d %s", room, n, payload)
		writeJSON(w, map[string]interface{}{"sent": n, "payload": string(payload)})
	})

	// 档次推荐：/api/preset?room=dev001&devices=20&uplink=50&mode=console|auth&apply=1
	// 按"上行总带宽 / 台数"算出每台可用峰值，再换成 cap / scale / fps。
	// 目的：授权时按档次一键下发低清档，中控回到插件默认档，安全又不用记参数。
	mux.HandleFunc("/api/preset", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		room := q.Get("room")
		if room == "" {
			room = "dev001"
		}
		devices := 1
		if v, err := strconv.Atoi(q.Get("devices")); err == nil && v > 0 {
			devices = v
		}
		uplink := 50.0
		if v, err := strconv.ParseFloat(q.Get("uplink"), 64); err == nil && v > 0 {
			uplink = v
		}
		mode := q.Get("mode")
		if mode == "" {
			mode = "console"
		}
		// 留 10% 余量：TCP/信令/重传都要占，满载跑满上行必然排队 → 反而卡
		// perDevKbps 是"每台可用峰值"，单位 kbps：上行 50M 走 10% 余量后按台数摊
		perDevKbps := uplink * 1000 * 0.9 / float64(devices)
		var scale float64
		fps := 30
		cap := int(perDevKbps * 1000) // bps
		// 局域网档：流量不出局域网，不吃外网上行，所以 cap 不按 uplink/台数算，
		// 只受 Wi-Fi 总带宽与电脑转发能力约束。几百台的瓶颈在 AP 与 CPU，不在 50M。
		if mode == "lan" {
			scale = 0.40
			fps = 30
			cap = 4000000
		} else if mode == "grid" {
			// 巡检缩略档：几百台同屏、每台只出一点点，点开的那台再切 lan
			scale = 0.20
			fps = 8
			cap = 400000
		} else if mode == "auth" {
			// 授权档：授权出去几十台，但同时被看的只有 10-20 路。
			// 按"同时路数"摊上行才有意义；按总台数摊会把每台压到看不了字。
			conc := 20
			if v, err := strconv.Atoi(q.Get("concurrent")); err == nil && v > 0 {
				conc = v
			} else if devices < 20 {
				conc = devices
			}
			perConcKbps := uplink * 1000 * 0.9 / float64(conc)
			cap = int(perConcKbps * 1000)
			scale = 0.35
			fps = 30
			if cap < 1000000 {
				scale = 0.32
				fps = 24
			}
			if cap > 1500000 {
				cap = 1500000
			}
			if cap < 500000 {
				cap = 500000
			}
			perDevKbps = perConcKbps
		} else {
			switch {
			case perDevKbps >= 2500:
				scale = 0.40
			case perDevKbps >= 1200:
				scale = 0.35
			default:
				scale = 0.30
				fps = 24
			}
			if cap > 4000000 {
				cap = 4000000
			}
			if cap < 600000 {
				cap = 600000
			}
		}
		base := cap * 3 / 5 // 稳态基线上限 = 峰值的 60%，余下留给突发，静态时不占
		p := map[string]interface{}{
			"mode":    mode,
			"devices": devices,
			"uplink":  uplink,
			"perDev":  roundKbps(perDevKbps),
			"scale":   scale,
			"fps":     fps,
			"cap":     cap,
			"bitrate": base,
		}
		if mode == "lan" || mode == "grid" {
			p["note"] = "局域网档：不占外网上行，只受 Wi-Fi 带宽与电脑转发能力约束"
			p["perDev"] = 0
		}
		if q.Get("apply") != "" && q.Get("apply") != "0" {
			msg := map[string]interface{}{"t": "cfg", "scale": strconv.FormatFloat(scale, 'f', 2, 64),
				"fps": fps, "bitrate": base, "cap": cap}
			payload, _ := json.Marshal(msg)
			h.mu.RLock()
			set := h.rooms["ctrl-"+room]
			h.mu.RUnlock()
			n := 0
			for c := range set {
				if err := c.send(payload); err == nil {
					n++
				}
			}
			h.mu.Lock()
			if h.profiles[room] == nil {
				h.profiles[room] = map[string]interface{}{"t": "cfg"}
			}
			for k, v := range msg {
				h.profiles[room][k] = v
			}
			h.mu.Unlock()
			p["sent"] = n
			p["payload"] = string(payload)
			log.Printf("preset room=%s mode=%s devices=%d perDev=%.0fkbps cap=%d scale=%.2f sent=%d",
				room, mode, devices, perDevKbps, cap, scale, n)
		}
		writeJSON(w, p)
	})

	static, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("embed web: %v", err)
	}
	// 网页必须每次拿最新：档位/按钮改过之后，浏览器缓存旧页面会把旧参数
	// 重新下发给设备（实测出现过 15fps/0.30 把画面拖回"越调越卡"的假象）。
	fileServer := http.FileServer(http.FS(static))
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store, max-age=0, must-revalidate")
		w.Header().Set("Pragma", "no-cache")
		w.Header().Set("Expires", "0")
		fileServer.ServeHTTP(w, r)
	}))

	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("AKUN Device Bridge signaling listening on %s", *addr)
	log.Printf("控制台: http://%s:%d/", firstNonLoopbackIPv4(), httpPortFromAddr(*addr))
	if *discPort > 0 {
		startDiscovery(*discPort, httpPortFromAddr(*addr))
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
