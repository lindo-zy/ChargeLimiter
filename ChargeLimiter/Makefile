APPLICATION_NAME = ChargeLimiter

# 主 App（UIKit 原生界面，入口 main 在 ui.mm；CLTestApp.m 仅模拟器测试用，不编译）。
ChargeLimiter_FILES = ui.mm \
	utils.mm \
	CLLocalization.mm \
	CLSimpleHTTPServer.m \
	UIKit/CLAPIClient.m \
	UIKit/CLBatteryManager.m \
	UIKit/CLDiagnosticCollector.m \
	UIKit/Controllers/CLAdvancedSettingsViewController.m \
	UIKit/Controllers/CLBatteryCompatibilityTestViewController.m \
	UIKit/Controllers/CLHelpViewController.m \
	UIKit/Controllers/CLMainViewController.m \
	UIKit/Controllers/CLSettingsViewController.m

ChargeLimiter_FRAMEWORKS = UIKit Foundation CoreGraphics CFNetwork CoreServices JavaScriptCore UserNotifications

# 私有框架走仓库 tbd 存根（与旧 Xcode Frameworks phase 一致）；
# libMobileGestalt/sqlite3/z 由 SDK 自带 tbd 提供。
ChargeLimiter_LDFLAGS = $(THEOS_PROJECT_DIR)/tbd/BackBoardServices.tbd \
	$(THEOS_PROJECT_DIR)/tbd/GraphicsServices.tbd \
	$(THEOS_PROJECT_DIR)/tbd/IOKit.tbd \
	-lMobileGestalt

# jbroot() 由静态 libroot.a 提供（roothide scheme 下 Theos 不自动链 -lroot，
# 与旧 Xcode roothide 配置一致：libroot.a 打进二进制，运行期自解析 jbroot）。
ChargeLimiter_LDFLAGS += -L$(THEOS)/vendor/lib -lroot

# CLDiagnosticCollector 等按包方案分支的宏（THEOS_PACKAGE_SCHEME_ROOTHIDE=1
# 由 Theos 按 scheme 自动定义）。-I 模拟 Xcode headermap：源码里按裸文件名
# 跨目录 import 根目录与 UIKit/ 的头文件。
ChargeLimiter_CFLAGS = -fobjc-arc -DCL_PACKAGE_ROOTHIDE=1 \
	-I$(THEOS_PROJECT_DIR)/ChargeLimiter \
	-I$(THEOS_PROJECT_DIR)/ChargeLimiter/UIKit \
	-Wno-module-import-in-extern-c

# .mm 里的 C++ lambda（BKSHIDEvent/CFNotificationCenter 回调）需要显式 C++
# 标准：Xcode 16.x 的 clang 默认仍是 gnu++98（lambda 直接语法报错），Xcode 26
# 默认 >=gnu++17 所以本地踩不到。原 Xcode 工程即 CLANG_CXX_LANGUAGE_STANDARD
# = c++14；OBJCCFLAGS 只作用于 .mm 编译，不影响 .m 的 C 模式。
ChargeLimiter_OBJCCFLAGS = -std=gnu++14

ChargeLimiter_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/entitlements/app.roothide.plist

ChargeLimiter_RESOURCE_FILES = Info.plist \
	lang.json \
	en.lproj \
	zh-Hans.lproj \
	AppIcon60x60@2x.png \
	AppIcon60x60@3x.png \
	AppIcon76x76@2x~ipad.png

ChargeLimiter_INSTALL_PATH = /Applications

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/application.mk
