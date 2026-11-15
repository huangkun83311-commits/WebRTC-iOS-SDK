ARCHS := arm64
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME := akund

# 仓库自带的 WebRTC 二进制（m108，ios-arm64 切片）
WEBRTC_DIR := $(THEOS_PROJECT_DIR)/../../WebRTC.xcframework/ios-arm64

akund_FILES := src/main.mm src/AkunCapture.mm src/AkunInjector.mm src/AkunRTC.mm src/AkunDiscovery.mm
akund_FRAMEWORKS := Foundation CoreVideo CoreGraphics CoreMedia QuartzCore IOSurface IOKit
# Linux 上没有 Apple 的 ld64，必须走 ld64.lld；macOS runner 用系统 ld64 即可
ifeq ($(shell uname -s),Darwin)
LINKER_FLAGS := -Wl,-undefined,dynamic_lookup -Wl,-adhoc_codesign
else
LINKER_FLAGS := -fuse-ld=lld -Wl,-undefined,dynamic_lookup -Wl,-adhoc_codesign
endif

akund_CFLAGS  += -fobjc-arc -stdlib=libc++ -F$(WEBRTC_DIR) -Wno-arc-retain-cycles
akund_CCFLAGS += -stdlib=libc++ $(LINKER_FLAGS)
akund_LDFLAGS += $(LINKER_FLAGS)
akund_LDFLAGS += -F$(WEBRTC_DIR) -framework WebRTC
# usr/bin 装二进制、usr/lib 装框架；App 形态下框架在 .app/Frameworks，两条 rpath 都留
akund_LDFLAGS += -Wl,-rpath,@executable_path/../lib -Wl,-rpath,@executable_path/Frameworks

include $(THEOS_MAKE_PATH)/tool.mk

before-package::
	@mkdir -p $(THEOS_STAGING_DIR)/usr/lib
	@cp -R $(WEBRTC_DIR)/WebRTC.framework $(THEOS_STAGING_DIR)/usr/lib/
	@$(THEOS)/bin/ldid -S"$(THEOS_STAGING_DIR)/usr/lib/WebRTC.framework/WebRTC" || true
	@$(THEOS)/bin/ldid -S"$$(pwd)/src/akund.entitlements" "$(THEOS_STAGING_DIR)/usr/bin/akund"