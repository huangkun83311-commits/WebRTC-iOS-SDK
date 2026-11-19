#!/bin/bash
# 组装 TrollStore 形态：Payload/AKUNBridge.app（外壳 App）+ Layout（与 deb 完全一致的落地结构）
#
# 关键：tipa 要跟 deb 一样「装完就是系统守护进程、无需打开 App」，
# 就必须让安装时把二进制和 LaunchDaemon 落到固定路径：
#   Layout/usr/bin/akund                      -> /usr/bin/akund
#   Layout/Library/LaunchDaemons/<主>.plist    -> /Library/LaunchDaemons/<主>.plist
#   （dpkgd 已并入 -daemon 进程，不再下发独立 plist）
# TrollStore 安装 tipa 时会把 Layout/ 原样复制到根文件系统（保留权限）。
set -e
export THEOS=${THEOS:-$HOME/theos}
cd "$(dirname "$0")"

WEBRTC_DIR="$(cd ../.. && pwd)/WebRTC.xcframework/ios-arm64"
OUT="packages"
APP="build/Payload/AKUNBridge.app"
LAYOUT="build/Layout"

echo "== 1/6 编 daemon =="
make -j4 >/dev/null
echo "== 2/6 编外壳 App =="
( cd app && make -j4 >/dev/null )

echo "== 3/6 组装 .app =="
rm -rf build
mkdir -p "$APP/Frameworks"
cp app/.theos/obj/debug/arm64/akunbridge "$APP/akunbridge"
cp .theos/obj/arm64/akund "$APP/akundd"
cp -R "$WEBRTC_DIR/WebRTC.framework" "$APP/Frameworks/"
cp app/Resources/Info.plist "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

echo "== 4/6 组装 Layout（与 deb 落地结构 1:1）=="
# deb 能完美运行靠三件套：二进制 /usr/bin/akund、框架 /usr/lib/WebRTC.framework（必须带，
# 二进制的 rpath 是 @executable_path/../lib）、两个 LaunchDaemon plist。tipa 必须完全照抄，
# 少一样就起不来（缺框架表现为 dyld 找不到 WebRTC、signal 6 崩溃）。
mkdir -p "$LAYOUT/usr/bin" "$LAYOUT/usr/lib" "$LAYOUT/Library/LaunchDaemons"
cp .theos/obj/arm64/akund "$LAYOUT/usr/bin/akund"
cp -R "$WEBRTC_DIR/WebRTC.framework" "$LAYOUT/usr/lib/"
cp layout-tipa/Library/LaunchDaemons/com.akun.akund.plist "$LAYOUT/Library/LaunchDaemons/"
chmod 0755 "$LAYOUT/usr/bin/akund"
chmod 0644 "$LAYOUT/Library/LaunchDaemons/"*.plist
# 框架必须 ad-hoc 签名，否则 roothide 拒绝加载（mapped file has no cdhash）
"$THEOS/bin/ldid" -S "$LAYOUT/usr/lib/WebRTC.framework/WebRTC" || echo "（Layout 框架签名跳过）"

echo "== 5/6 ldid 签名（entitlements 必须内嵌）=="
"$THEOS/bin/ldid" -S"$PWD/src/akund.entitlements" "$APP/akunbridge"
"$THEOS/bin/ldid" -S"$PWD/src/akund.entitlements" "$APP/akundd"
"$THEOS/bin/ldid" -S"$PWD/src/akund.entitlements" "$LAYOUT/usr/bin/akund"
"$THEOS/bin/ldid" -S"$APP/Frameworks/WebRTC.framework/WebRTC" \
  || echo "（框架签名跳过：TrollStore 安装时会重签整个 .app）"
chmod 0755 "$APP/akunbridge" "$APP/akundd" "$LAYOUT/usr/bin/akund"

echo "== 6/6 打 zip -> .tipa（Payload + Layout）=="
mkdir -p "$OUT"
rm -f "$OUT/AKUNBridge.tipa"
( cd build && zip -qry "../$OUT/AKUNBridge.tipa" Payload Layout )
echo "产物：$(pwd)/$OUT/AKUNBridge.tipa  $(du -h "$OUT/AKUNBridge.tipa" | cut -f1)"
echo "--- 包内 Layout 校验 ---"
unzip -l "$OUT/AKUNBridge.tipa" | grep -E "Layout/usr/bin|LaunchDaemons|WebRTC.framework/WebRTC$"
