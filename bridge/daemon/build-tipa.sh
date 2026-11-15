#!/bin/bash
# 组装 TrollStore 形态：Payload/AKUNBridge.app（外壳 App + akundd + WebRTC.framework）
set -e
export THEOS=${THEOS:-$HOME/theos}
cd "$(dirname "$0")"

WEBRTC_DIR="$(cd ../.. && pwd)/WebRTC.xcframework/ios-arm64"
OUT="packages"
APP="build/Payload/AKUNBridge.app"

echo "== 1/5 编 daemon =="
make -j4 >/dev/null
echo "== 2/5 编外壳 App =="
( cd app && make -j4 >/dev/null )

echo "== 3/5 组装 .app =="
rm -rf build
mkdir -p "$APP/Frameworks"
cp app/.theos/obj/debug/arm64/akunbridge "$APP/akunbridge"
cp .theos/obj/debug/arm64/akund "$APP/akundd"
cp -R "$WEBRTC_DIR/WebRTC.framework" "$APP/Frameworks/"
cp app/Resources/Info.plist "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

echo "== 4/5 ldid 签名（entitlements 必须内嵌，否则 TrollStore 拿不到权限）=="
"$THEOS/bin/ldid" -S"$PWD/src/akund.entitlements" "$APP/akunbridge"
"$THEOS/bin/ldid" -S"$PWD/src/akund.entitlements" "$APP/akundd"
"$THEOS/bin/ldid" -S"$APP/Frameworks/WebRTC.framework/WebRTC" \
  || echo "（框架签名跳过：ldid 不认这个 fat 头，TrollStore 安装时会重签整个 .app）"
chmod 0755 "$APP/akunbridge" "$APP/akundd"

echo "== 5/5 打 zip -> .tipa =="
mkdir -p "$OUT"
rm -f "$OUT/AKUNBridge.tipa"
( cd build && zip -qry "../$OUT/AKUNBridge.tipa" Payload )
echo "产物：$(pwd)/$OUT/AKUNBridge.tipa  $(du -h "$OUT/AKUNBridge.tipa" | cut -f1)"