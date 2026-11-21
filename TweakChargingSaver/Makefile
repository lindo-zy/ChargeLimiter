TWEAK_NAME = CLChargingSaver

# 充电屏保（锁屏策略卡）：仅注入 SpringBoard（filter 见 CLChargingSaver.plist）。
# 参考 Metis Modules/Charging 的宿主/让位/挂载模式；数据读 jbroot 内 saver_state
# 镜像 + IOKit 直读，命令经 com.chargelimiter.saveraction notify 回 daemon。
CLChargingSaver_FILES = CLChargingSaverTweak.m

CLChargingSaver_FRAMEWORKS = Foundation UIKit CoreGraphics

CLChargingSaver_CFLAGS = -fobjc-arc

CLChargingSaver_LDFLAGS = ../tbd/IOKit.tbd

# jbroot() 静态链接（saver_state 镜像路径解析），同 App/Daemon 的 -lroot 约定。
CLChargingSaver_LDFLAGS += -L$(THEOS)/vendor/lib -lroot

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
