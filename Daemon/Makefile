TOOL_NAME = ChargeLimiterDaemon

# 守护进程：二进制直接安装进 App bundle（旧 Xcode 流程是把 daemon.app 的二进制
# 拷进 ChargeLimiter.app，这里由 INSTALL_PATH 直接落到 staging 的同一目录）。
# daemon 与 app 共享 utils.mm / CLSimpleHTTPServer.m，按 Metis 子项目惯例用
# ../ 相对路径引用（普通 .m/.mm 无预处理中间产物，可安全穿越）。
ChargeLimiterDaemon_FILES = ../ChargeLimiter/daemon.mm \
	../ChargeLimiter/utils.mm \
	../ChargeLimiter/CLSimpleHTTPServer.m

ChargeLimiterDaemon_FRAMEWORKS = Foundation UserNotifications CoreServices

ChargeLimiterDaemon_LDFLAGS = $(THEOS_PROJECT_DIR)/tbd/BackBoardServices.tbd \
	$(THEOS_PROJECT_DIR)/tbd/IOKit.tbd \
	-lMobileGestalt -lsqlite3 -lz

# jbroot() 静态链接，见 ChargeLimiter/Makefile 同注释。
ChargeLimiterDaemon_LDFLAGS += -L$(THEOS)/vendor/lib -lroot

ChargeLimiterDaemon_CFLAGS = -fobjc-arc \
	-I$(THEOS_PROJECT_DIR)/ChargeLimiter \
	-I$(THEOS_PROJECT_DIR)/ChargeLimiter/UIKit \
	-Wno-module-import-in-extern-c

# 同 ChargeLimiter/Makefile：CI 的 Xcode 16.x clang 默认 gnu++98，需显式标准。
ChargeLimiterDaemon_OBJCCFLAGS = -std=gnu++14

ChargeLimiterDaemon_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/entitlements/daemon.roothide.plist

ChargeLimiterDaemon_INSTALL_PATH = /Applications/ChargeLimiter.app

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk
