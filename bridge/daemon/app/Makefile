ARCHS := arm64
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME := akunbridge
akunbridge_FILES := main.mm
akunbridge_FRAMEWORKS := UIKit Foundation CoreGraphics
akunbridge_CFLAGS += -fobjc-arc -stdlib=libc++
akunbridge_CCFLAGS += -stdlib=libc++ -fuse-ld=lld
akunbridge_LDFLAGS += -fuse-ld=lld -Wl,-adhoc_codesign

include $(THEOS_MAKE_PATH)/tool.mk