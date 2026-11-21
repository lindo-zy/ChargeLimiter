TWEAK_NAME = CLThermalSim

# 温控模拟执行端：仅注入 thermalmonitord（filter 见 CLThermalSim.plist，
# Theos 按 TWEAK_NAME 自动安装同名 filter plist）。
CLThermalSim_FILES = CLThermalSimTweak.m

CLThermalSim_FRAMEWORKS = Foundation

CLThermalSim_CFLAGS = -fobjc-arc

CLThermalSim_LDFLAGS = $(THEOS_PROJECT_DIR)/tbd/IOKit.tbd

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
