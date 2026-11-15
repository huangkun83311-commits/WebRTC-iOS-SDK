# Theos — Dopamine 隐根（rootless）打包
# 需要：THEOS 环境 + iOS 15/16 SDK
# 产物：.packages/com.akun.akunbridge_*_iphoneos-arm64.deb
# 安装：dpkg -i 或 Sileo/Zebra；装完 respring 生效

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# Dopamine / 无根越狱必须加这一行，否则装到 /Library 而不是 /var/jb/Library
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AkunBridge
AkunBridge_FILES = Tweak.xm
AkunBridge_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AkunBridge_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
