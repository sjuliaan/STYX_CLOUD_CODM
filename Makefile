TARGET := iphone:clang:latest:14.0
ARCHS := arm64
DEBUG := 0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME := styx

IMGUI := third_party/imgui

styx_FILES := $(wildcard src/*.mm src/*.m src/*.cpp)
styx_FILES += third_party/fishhook/fishhook.c
styx_FILES += $(IMGUI)/imgui.cpp $(IMGUI)/imgui_draw.cpp $(IMGUI)/imgui_tables.cpp $(IMGUI)/imgui_widgets.cpp
styx_FILES += $(IMGUI)/backends/imgui_impl_metal.mm

styx_CFLAGS := -fobjc-arc -DNDEBUG -Isrc -Ithird_party/fishhook -I$(IMGUI) -I$(IMGUI)/backends
styx_CCFLAGS := -std=c++17 -fno-exceptions -fno-rtti -O2 -DNDEBUG -I$(IMGUI) -I$(IMGUI)/backends

styx_LDFLAGS := -install_name @executable_path/Frameworks/libstyx.dylib
styx_FRAMEWORKS := Foundation UIKit CoreGraphics QuartzCore Metal MetalKit
styx_INSTALL_PATH := /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
