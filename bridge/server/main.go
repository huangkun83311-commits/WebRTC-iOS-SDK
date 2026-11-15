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
	"io/fs"
	"log"
	"net"
	"net/http"
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

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade failed: %v", err)
		return
	}

	c := &client{conn: conn, room: room, role: role}
	n := h.join(c)
	log.Printf("join room=%s role=%s peers=%d", room, role, n)
	h.notify(c, "_peerJoined")

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

func main() {
	addr := flag.String("addr", ":8080", "监听地址，例如 :8080")
	discPort := flag.Int("disc", 19951, "UDP 自动发现端口，0 表示关闭")
	flag.Parse()

	h := newHub()

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
		for _, k := range []string{"scale", "fps", "bitrate"} {
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
		log.Printf("config room=%s sent=%d %s", room, n, payload)
		writeJSON(w, map[string]interface{}{"sent": n, "payload": string(payload)})
	})

	static, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("embed web: %v", err)
	}
	mux.Handle("/", http.FileServer(http.FS(static)))

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
