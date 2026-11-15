ARCHS := arm64
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME := akund

# 仓库自带的 WebRTC 二进制（m108，ios-arm64 切片）
WEBRTC_DIR := $(THEOS_PROJECT_DIR)/../../WebRTC.xcframework/ios-arm64

akund_FILES := src/main.mm src/AkunCapture.mm src/AkunInjector.mm src/AkunRTC.mm src/AkunDiscovery.mm src/AkunOrientation.mm src/vendor/STHIDEventGenerator.mm
akund_FRAMEWORKS := Foundation UIKit CoreVideo CoreGraphics CoreMedia QuartzCore IOSurface IOKit Accelerate CoreImage Metal
# Linux 上没有 Apple 的 ld64，必须走 ld64.lld；macOS runner 用系统 ld64 即可
ifeq ($(shell uname -s),Darwin)
LINKER_FLAGS := -Wl,-undefined,dynamic_lookup -Wl,-adhoc_codesign
else
LINKER_FLAGS := -fuse-ld=lld -Wl,-undefined,dynamic_lookup -Wl,-adhoc_codesign
endif

akund_CFLAGS  += -fobjc-arc -stdlib=libc++ -F$(WEBRTC_DIR) -Wno-arc-retain-cycles
# AKUN 源码里有新版 clang 才认识的 #pragma clang diagnostic ignored 分组名，
# 老 clang 会把它当 error；忽略「未知警告名」即可，不影响行为。
akund_CFLAGS  += -Wno-unknown-warning-option
# AKUN 正式包关了断言；它源码里 tap: 会传 delay=0 触发自身断言，
# 我们保持断言关闭，行为才和它一致（否则一点击就 abort）。
akund_CFLAGS  += -DNS_BLOCK_ASSERTIONS=1
akund_CCFLAGS += -stdlib=libc++ $(LINKER_FLAGS)
akund_LDFLAGS += $(LINKER_FLAGS)
akund_LDFLAGS += -F$(WEBRTC_DIR) -framework WebRTC
# usr/bin 装二进制、usr/lib 装框架；App 形态下框架在 .app/Frameworks，两条 rpath 都留
akund_LDFLAGS += -Wl,-rpath,@executable_path/../lib -Wl,-rpath,@executable_path/Frameworks

include $(THEOS_MAKE_PATH)/tool.mk

before-package::
	@mkdir -p $(THEOS_STAGING_DIR)/usr/lib
	@cp -R $(WEBRTC_DIR)/WebRTC.framework $(THEOS_STAGING_DIR)/usr/lib/
	@# 必须给框架做 ad-hoc 签名：roothide/rootless 内核拒绝加载「完全未签名」的 dylib
	@# （真机报 mapped file has no cdhash, completely unsigned）。注意 -S 与路径之间要有空格，
	@# 写成 -S"$$path" 会被当成「用该二进制自身当 entitlements」，ldid 报错但退出码被吞掉。
	@$(THEOS)/bin/ldid -S "$(THEOS_STAGING_DIR)/usr/lib/WebRTC.framework/WebRTC"
	@$(THEOS)/bin/ldid -S"$$(pwd)/src/akund.entitlements" "$(THEOS_STAGING_DIR)/usr/bin/akund"