package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// 授权（对外给客户看/控）：
// 服务端用 -key 作为签名密钥。不给 -key 就是现在的局域网免验证模式；
// 给了 -key 之后，所有 WS 连接必须带 ?k=，否则 403。
//
// 一房一码：令牌绑定「设备名」而不是完整房间名（video-dev001 / ctrl-dev001 同一个设备，
// 客户要能一边看一边控，用两个码会很难发），并且带过期时间，过期自动失效。
//
// 令牌形式：<过期秒> - <HMAC-SHA256(设备名|过期秒) 前 16 字节>
// 服务端无状态校验，重启不丢；换 -key 即全体旧授权立刻作废。
var authSecret string

func authEnabled() bool { return authSecret != "" }

// deviceOf 把房间名还原成设备名：video-dev001 / ctrl-dev001 / rtp-dev001 → dev001
func deviceOf(room string) string {
	for _, p := range []string{"video-", "ctrl-", "rtp-", "grid-"} {
		if strings.HasPrefix(room, p) {
			return strings.TrimPrefix(room, p)
		}
	}
	return room
}

func tokenSign(device string, expire int64) string {
	mac := hmac.New(sha256.New, []byte(authSecret))
	mac.Write([]byte(device + "|" + strconv.FormatInt(expire, 10)))
	return hex.EncodeToString(mac.Sum(nil))[:16]
}

func makeToken(device string, minutes int) (string, int64) {
	if minutes <= 0 {
		minutes = 60
	}
	expire := time.Now().Unix() + int64(minutes)*60
	return strconv.FormatInt(expire, 10) + "-" + tokenSign(device, expire), expire
}

func verifyToken(device, k string) bool {
	i := strings.Index(k, "-")
	if i <= 0 {
		return false
	}
	expire, err := strconv.ParseInt(k[:i], 10, 64)
	if err != nil || time.Now().Unix() > expire {
		return false
	}
	sig := tokenSign(device, expire)
	return hmac.Equal([]byte(sig), []byte(k[i+1:]))
}

// authOK：k 等于主密钥（本机/中控台直连用），或者是本设备名的有效令牌。
func authOK(r *http.Request) bool {
	if !authEnabled() {
		return true
	}
	k := r.URL.Query().Get("k")
	if k == "" {
		return false
	}
	if hmac.Equal([]byte(k), []byte(authSecret)) {
		return true
	}
	return verifyToken(deviceOf(r.URL.Query().Get("room")), k)
}

// handleAuth 生成一条授权链接：/api/auth?room=dev001&min=60&k=<主密钥>
func handleAuth(w http.ResponseWriter, r *http.Request) {
	if !authEnabled() {
		writeJSON(w, map[string]interface{}{
			"ok": false,
			"note": "服务端没开授权（启动参数没给 -key）。局域网直接用 http://<ip>:8080/?room=dev001 即可",
		})
		return
	}
	if !hmac.Equal([]byte(r.URL.Query().Get("k")), []byte(authSecret)) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	dev := r.URL.Query().Get("room")
	if dev == "" {
		http.Error(w, "room is required", http.StatusBadRequest)
		return
	}
	dev = deviceOf(dev)
	min, _ := strconv.Atoi(r.URL.Query().Get("min"))
	tok, expire := makeToken(dev, min)
	host := r.Host
	scheme := "http"
	if r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	link := fmt.Sprintf("%s://%s/?room=%s&k=%s", scheme, host, dev, tok)
	writeJSON(w, map[string]interface{}{
		"ok":     true,
		"device": dev,
		"key":    tok,
		"expire": expire,
		"expireAt": time.Unix(expire, 0).Format("2006-01-02 15:04"),
		"url":    link,
	})
}
