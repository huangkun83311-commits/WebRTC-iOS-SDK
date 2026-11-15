# AKUN Device Bridge —— 手机画面实时回传 + 电脑控制手机

面向你的环境：**Dopamine 隐根（rootless，iOS 15~16）或 TrollStore**。

## 一、这套东西解决什么

| 能力 | 组件 | 状态 |
|---|---|---|
| 手机整屏实时画面 | ReplayKit 扩展 + WebRTC 推流 | 代码完成，需在 Xcode 编译 |
| 电脑端看画面 | 浏览器网页（纯前端，无需安装） | 已完成 |
| 电脑点击/滑动/长按 → 手机真实响应 | SpringBoard tweak + IOHIDEvent 注入 | 代码完成，**注入相位常量需真机校准** |
| 信令中继 / 指令中继 | Go 服务端（已编译+冒烟测试通过） | ✅ 已验证 |
| NAT 穿透 | coturn 配置 | 配置完成 |

## 二、架构（为什么这么分层）

```
┌─────────────┐        WebRTC (P2P 视频, 720x1280)        ┌──────────────┐
│  浏览器      │◄───────────────────────────────────────│ 手机 ReplayKit│
│  (网页控制台) │                                        │ 广播扩展      │
│             │──── ws: /ws?room=video-dev001 ────────►│ (信令)        │
│             │                                        └──────────────┘
│             │        ws: /ws?room=ctrl-dev001
│             │◄───────────────────────────────────────►┌──────────────┐
└─────────────┘        {t:"d",x:0.42,y:0.66}            │ SpringBoard   │
                                                       │ Tweak → 注入  │
                                                       └──────────────┘
                    ▲                    ▲
                    └──── Go 服务端 ──────┘（房间广播，不碰媒体流）
```

三个刻意的设计决定：

1. **控制走 WebSocket，不走 DataChannel。** 控制流量只有几百字节/秒，WS 完全够；用 DataChannel 的话手机端要在扩展 + tweak 里各维护一条 PeerConnection，复杂度和故障点翻倍。
2. **注入放在 SpringBoard，不放 App。** iOS 沙盒禁止 App 向其它 App 注入触摸；SpringBoard 进程本身持有 HID 派发权限，在它的上下文里 `IOHIDEventSystemClientDispatchEvent` 才能真正点到桌面和其它 App。
3. **视频房和控制房分开（`video-*` / `ctrl-*`）。** 避免浏览器的控制消息被扩展收到、扩展的 SDP 被 tweak 收到。

## 三、目录

```
akun-device-bridge/
├── server/                      # Go 信令 + 指令中继（已编译、已测试）
│   ├── main.go
│   ├── web/index.html           # 浏览器控制台（内嵌进二进制）
│   ├── smoke-test.mjs           # 冒烟测试，5 项全 PASS
│   ├── bridge-server.exe        # 已编译好的 Windows 版
│   └── Dockerfile 说明见下
├── turn/
│   ├── turnserver.conf          # coturn 配置
│   └── docker-compose.yml
├── ios/ScreenShare/
│   └── ScreenBroadcastHandler.swift   # 替换原仓库 SampleHandler
└── tweak/                       # Theos rootless tweak（注入 + 触摸合成）
    ├── Tweak.xm
    ├── Makefile
    └── AkunBridge.plist
```

## 四、部署步骤

### 1. 服务端（Linux 服务器，你有现成机器）

```bash
cd server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bridge-server .
# 直接跑
./bridge-server -addr :8080
# 生产建议前置 Caddy/nginx 走 wss
```

冒烟测试（本机已跑过，5 项全 PASS）：
```bash
node smoke-test.mjs
```

浏览器控制台就是 `http://服务器IP:8080/`，打开后填设备 ID，点「连接」。

### 2. coturn（跨运营商才需要，同一局域网可以跳过）

```bash
cd turn
# 先把 turnserver.conf 里的 YOUR_PUBLIC_IP 和 CHANGE_ME_TO_A_LONG_RANDOM_SECRET 改掉
docker compose up -d
```

再在 `web/index.html` 顶部的 `window.__TURN__` 处填：
```html
<script>
window.__TURN__ = { urls: 'turn:你的公网IP:3478', username: 'akun', credential: '密码' };
</script>
```

### 3. 手机视频端（Xcode 编译）

在 `WebRTCiOSSDK.xcodeproj` 上做这几步：

1. `ScreenShare` target 里删掉 `SampleHandler.swift`，把 `ios/ScreenShare/ScreenBroadcastHandler.swift` 加进去；
   注意类名要保持与 Info.plist 的 `NSExtensionPrincipalClass` 一致 —— 需要把 Info.plist 里的
   `$(PRODUCT_MODULE_NAME).SampleHandler` 改成 `$(PRODUCT_MODULE_NAME).ScreenBroadcastHandler`。
2. `WebRTC.xcframework` 要**同时**拖进 `ScreenShare` target 的 Frameworks（原仓库只给了主 App）。
3. `ScreenShare/Info.plist` 加兜底配置（自签/巨魔下 App Group 不通时用它）：
   ```xml
   <key>WebRTCServerURL</key><string>ws://你的服务器IP:8080</string>
   <key>WebRTCStreamId</key><string>dev001</string>
   ```
4. 编译：
   ```bash
   xcodebuild -project WebRTCiOSSDK.xcodeproj -scheme "WebRTC-Sample-App" \
     -configuration Release -destination "generic/platform=iOS" \
     -archivePath build/App.xcarchive archive
   ```
   打包 IPA 见 `../WebRTC-iOS-SDK/.github/workflows/build-ipa.yml`（免 Mac 走 GitHub Actions）。

> **编译报错自查**：如果 `videoSource.capturer(videoCapturer, didCapture: frame)` 报
> "no exact matches"，说明这个 WebRTC 版本的 Swift 重命名是 `didCaptureVideoFrame`，
> 改成 `videoSource.capturer(videoCapturer, didCaptureVideoFrame: frame)` 即可。

### 4. 手机控制端（Theos tweak）

```bash
# 手机上先建配置
ssh root@手机IP
cat > /var/jb/var/mobile/Library/Preferences/com.akun.bridge.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ServerBase</key><string>ws://你的服务器IP:8080</string>
  <key>DeviceId</key><string>dev001</string>
</dict></plist>
EOF

# 编译
cd tweak
make package FINALPACKAGE=1        # rootless，产物在 .packages/
# 安装
scp .packages/*.deb root@手机IP:/tmp/
ssh root@手机IP "dpkg -i /tmp/com.akun.akunbridge_*.deb && killall -9 SpringBoard"
```

看日志：
```bash
ssh root@手机IP "tail -f /var/jb/var/log/syslog | grep AkunBridge"
```

## 五、真机校准清单（注入不生效时按顺序排查）

这块是**唯一需要真机调试的部分**，因为 IOHIDEvent 的相位位定义在不同 iOS 版本上有差异：

1. 日志里有 `[AkunBridge] down 0.412,0.660` → 指令收到了，问题在注入侧
2. 完全没反应 → 打开 `Tweak.xm` 里被注释掉的
   `IOHIDEventSetIntegerValue(hand, 0x00030000, 1)` 和 `0x00030001` 两行再试
3. 还是没反应 → 把 `HID_PHASE_BEGAN/MOVED/ENDED` 从 `1/2/4` 换成 `1/2/3`
4. 指针位置偏 → 把 `USE_NORMALIZED_COORDS` 改成 `0`（改成像素坐标）
5. 只有按下没有抬起（图标一直抖） → `HID_PHASE_ENDED` 的值不对，试 `3` 或 `5`

改完 `make package FINALPACKAGE=1` 重装 + `killall -9 SpringBoard`，不用重启。

## 六、已验证 / 未验证（实话）

**已验证（在这台 Windows 上真跑过）**
- Go 服务端编译通过（go1.26.0）
- `/healthz` `/` 静态页正常
- 中继冒烟测试 5 项全 PASS：`peerJoined`、浏览器→手机、手机→浏览器、跨房隔离、`peerLeft`
- 原仓库 4 个会导致崩溃的 bug 已修（App Group 字符串、扩展 entitlement、`preferredExtension`、强解包）

**未验证（必须在你那边跑）**
- Swift 扩展代码：手头没有 macOS/Xcode，**一行都没编译过**
- Theos tweak：同上，没编译过；IOHIDEvent 相位常量必须真机校准
- 浏览器 WebRTC 收流：没在真实浏览器里连过 iOS 端

我不给你「应该可以」这种话。上面三块，你给我跑起来的日志（`os_log` / `syslog` / 浏览器 console），我按日志改。
