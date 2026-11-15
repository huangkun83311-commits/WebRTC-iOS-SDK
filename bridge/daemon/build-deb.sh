#!/bin/bash
# 出 Dopamine / rootless 用的 deb：arm64 与 arm64e 两种包都打
#
# 为什么要两份：A12 及以上机型的 Dopamine 是 rootless + 系统架构 iphoneos-arm64e，
# dpkg 会因为 "package architecture (iphoneos-arm64) does not match system (iphoneos-arm64e)"
# 直接拒绝安装。二进制本身还是 arm64（arm64 在 arm64e 设备上能正常跑），只需要改 control 里的架构声明。
#
# 另外：DEBIAN/postinst 必须带可执行位，否则 dpkg 会静默跳过它 —— 而它正是
# "装完把 daemon 拉起来" 的那一步。Windows 上 git 不记可执行位，所以这里强制 chmod。
set -e
export THEOS=${THEOS:-$HOME/theos}
cd "$(dirname "$0")"

chmod 0755 layout/DEBIAN/postinst layout/DEBIAN/prerm 2>/dev/null || true

make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1

ORIG=$(ls packages/*.deb | head -1)
echo "原始包：$ORIG"

# 校验：包内必须带 postinst / prerm 且可执行
WORK=$(mktemp -d)
dpkg-deb -R "$ORIG" "$WORK"
echo "-- 包内 DEBIAN 目录 --"
ls -l "$WORK/DEBIAN"
if [ ! -f "$WORK/DEBIAN/postinst" ]; then
    echo "ERROR: 包里没有 DEBIAN/postinst，装完不会启动 daemon" >&2
    exit 1
fi
if [ ! -x "$WORK/DEBIAN/postinst" ]; then
    echo "ERROR: postinst 没有可执行位，dpkg 会跳过它" >&2
    exit 1
fi

# arm64e 版：只改 control 的架构声明，其余内容逐字节一致
awk '/^Architecture:/{print "Architecture: iphoneos-arm64e"; next} {print}' \
    "$WORK/DEBIAN/control" > "$WORK/DEBIAN/control.new"
mv "$WORK/DEBIAN/control.new" "$WORK/DEBIAN/control"

OUT="packages/$(basename "$ORIG" | sed 's/iphoneos-arm64/iphoneos-arm64e/')"
dpkg-deb -b -Zxz "$WORK" "$OUT"
rm -rf "$WORK"

echo "产物：$(pwd)/packages/"
ls -l packages/
