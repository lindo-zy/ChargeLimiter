export ARCHS = arm64 arm64e

# 统一 Theos 构建入口（roothide-only）。
# TARGET / THEOS_PACKAGE_SCHEME 由根 build.sh 按 ios16 / ios17 双目标覆盖；
# 这里给出与 ios16 目标一致的默认值。Theos 用 /Users/xiao/dev/theos-roothide
# （build.sh 已处理；直接 make 时请自行 export THEOS）。
TARGET ?= iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME ?= roothide
export TARGET THEOS_PACKAGE_SCHEME

export DEBUG = 0
export FINALPACKAGE = 1

# 30k 行遗留 ObjC++（UIWebView 悬浮窗、openURL: 等刻意保留的旧 API）在
# Xcode 下并非 -Werror 编译；迁移期沿用宽松策略，警告照常打印但不阻断。
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += ChargeLimiter
SUBPROJECTS += Daemon
SUBPROJECTS += Tweak

include $(THEOS_MAKE_PATH)/aggregate.mk
