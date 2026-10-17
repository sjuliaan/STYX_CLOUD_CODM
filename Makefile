TARGET := iphone:clang:latest:14.0
ARCHS := arm64
DEBUG := 0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME := styx

styx_FILES := $(wildcard src/*.mm src/*.m src/*.cpp)
styx_FILES += third_party/fishhook/fishhook.c
styx_CFLAGS := -fobjc-arc -Isrc -Ithird_party/fishhook -DNDEBUG
styx_CCFLAGS := -std=c++17 -fno-exceptions -fno-rtti -O2
styx_LDFLAGS := -install_name @executable_path/Frameworks/libstyx.dylib
styx_FRAMEWORKS := Foundation UIKit CoreGraphics QuartzCore
styx_INSTALL_PATH := /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
