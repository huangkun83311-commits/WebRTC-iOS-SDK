ARCHS := arm64
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME := akunbridge
akunbridge_FILES := main.mm
akunbridge_FRAMEWORKS := UIKit Foundation CoreGraphics
akunbridge_CFLAGS += -fobjc-arc -stdlib=libc++
ifeq ($(shell uname -s),Darwin)
APP_LINKER := -Wl,-adhoc_codesign
else
APP_LINKER := -fuse-ld=lld -Wl,-adhoc_codesign
endif

akunbridge_CCFLAGS += -stdlib=libc++ $(APP_LINKER)
akunbridge_LDFLAGS += $(APP_LINKER)

include $(THEOS_MAKE_PATH)/tool.mk