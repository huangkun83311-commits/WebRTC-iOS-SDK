# akund — 手机侧常驻守护进程（纯 WebRTC）

对齐 TrollVNC/AKUN 的工作方式（独立进程 + entitlements 直取屏幕 + 直接注入 HID），
但把传输层从 RFB/noVNC 换成 WebRTC：电脑端是浏览器原生 `RTCPeerConnection`。

```
手机 akund ── WS 信令 ──┐
   │  IOMobileFramebuffer→IOSurface→CVPixelBuffer→H264(WebRTC)  ├─ 电脑浏览器（video-<id>）
   └─ IOHIDEvent 注入 ←── {t:d/m/u} 控制 WS（ctrl-<id>）────────┘
```

## 两种产物

| 形态 | 适用 | 进程拉起方式 | 框架位置 |
|---|---|---|---|
| `*.deb` | Dopamine 隐根（rootless） | LaunchDaemon `com.akun.bridge`（mobile 用户、RunAtLoad+KeepAlive） | `/var/jb/usr/lib/WebRTC.framework` |
| `AKUNBridge.tipa` | TrollStore | App 内 `posix_spawn` 拉起 `akundd`，5 秒看门狗保活 | `.app/Frameworks/WebRTC.framework` |

同一个 `akund` 二进制，rpath 同时带 `@executable_path/../lib` 与 `@executable_path/Frameworks`。

## 构建

```bash
export THEOS=$HOME/theos          # 需要 Theos + iPhoneOS16.5.sdk（Linux 上还要 ld64.lld + libc++）
bash build-deb.sh                 # -> packages/com.akun.bridge_1.0.0_iphoneos-arm64.deb
bash build-tipa.sh                # -> packages/AKUNBridge.tipa
```

两个坑（已在 Makefile / 脚本里处理）：

1. entitlements **必须显式签**：Theos 的 `$(THEOS_PROJECT_DIR)` 在签名步骤里不展开，
   只用 `_CODESIGN_FLAGS` 会得到 ad-hoc 签名、没有 entitlements，装上后拿不到 HID/IOSurface 权限。
2. 交叉编译必须 `-fuse-ld=lld` + `-stdlib=libc++`，且 `ldid` 对完全未签名的 Mach-O 会报
   `Unknown header magic`，所以链接时先加 `-Wl,-adhoc_codesign`。

## 配置

`/var/jb/var/mobile/Library/Preferences/com.akun.bridge.plist`（非 rootless 回落 `/var/mobile/...`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ServerBase</key><string>http://192.168.1.100:8080</string>
	<key>DeviceId</key><string>dev001</string>
</dict>
</plist>
```

tipa 形态可以直接在 App 里填这两项并点「保存并启动」，App 会写进同一个 plist。

## 控制协议

浏览器 → 手机（`ctrl-<DeviceId>`）：

| 消息 | 含义 |
|---|---|
| `{"t":"d","x":0.5,"y":0.3}` | 按下（坐标归一化 0~1） |
| `{"t":"m","x":..,"y":..}` | 移动 |
| `{"t":"u","x":..,"y":..}` | 抬起 |
| `{"t":"tap","x":..,"y":..}` | 点击 |
| `{"t":"swipe","x":..,"y":..,"x2":..,"y2":..}` | 滑动 |
| `{"t":"k","code":"home"}` | 回桌面（下缘上滑手势） |

视频：浏览器在 `video-<DeviceId>` 发 recvonly offer，手机回 answer + candidate。

## 已验证 / 未验证（实话）

已验证（有编译与二进制证据）：

- 在 Ubuntu 22.04 + Theos 上完整编译通过：arm64 Mach-O，`ld64.lld` 链接，`ldid` 签名；
- deb 内 `var/jb/usr/bin/akund` 带 entitlements（`ldid -e` 能读出 plist），`WebRTC.framework` 一并入包；
- tipa 内 `akundd` / `akunbridge` 均带 entitlements，`WebRTC.framework` 在 `.app/Frameworks`；
- `akund` 的 LC_RPATH 同时包含 `/var/jb/usr/lib`（deb）与 `@executable_path/Frameworks`（tipa）。

未验证（**都必须在真机上跑过才能说"能用"**）：

- `IOMobileFramebufferOpen(service, task, 0, &fb)` 的服务/类型参数在各 iOS 版本上是否一致；
- `IOMobileFramebufferGetLayerDefaultSurface(fb, 0, &surface)` 返回的 surface 是否需要旋转/镜像；
- `CARenderServerRenderDisplay` 兜底路径是否可用（surface 尺寸写死 1170x2532，需按机型改）；
- HID phase 常量当前是 `1/2/4`（备选 `1/2/3`），未在真机上确认哪一种能触发；
- senderID `0x8000000817319372` 是否被 SpringBoard 接受（不行就试 `0x8000000817319384`）；
- TrollStore 下 App `posix_spawn` 拉起的 `akundd` 是否继承到足够的权限。