#!/bin/bash
# 出 Dopamine / rootless 用的 deb：arm64 与 arm64e 两种包都打
#
# 为什么要两份：A12 及以上机型的 Dopamine 是 rootless + 系统架构 iphoneos-arm64e，
# dpkg 会因为 "package architecture (iphoneos-arm64) does not match system (iphoneos-arm64e)"
# 直接拒绝安装。二进制本身还是 arm64（arm64 在 arm64e 设备上能正常跑），只需要改 control 里的架构声明。
set -e
export THEOS=${THEOS:-$HOME/theos}
cd "$(dirname "$0")"

make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1

ORIG=$(ls packages/*.deb | head -1)
echo "原始包：$ORIG"

WORK=$(mktemp -d)
dpkg-deb -R "$ORIG" "$WORK"
awk '/^Architecture:/{print "Architecture: iphoneos-arm64e"; next} {print}' \
    "$WORK/DEBIAN/control" > "$WORK/DEBIAN/control.new"
mv "$WORK/DEBIAN/control.new" "$WORK/DEBIAN/control"

OUT="packages/$(basename "$ORIG" | sed 's/iphoneos-arm64/iphoneos-arm64e/')"
dpkg-deb -b -Zxz "$WORK" "$OUT"
rm -rf "$WORK"

echo "产物：$(pwd)/packages/"
ls -l packages/