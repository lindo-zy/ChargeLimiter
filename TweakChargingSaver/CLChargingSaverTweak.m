// CLChargingSaver —— ChargeLimiter 充电屏保（锁屏策略卡）执行端，仅注入 SpringBoard。
//
// 宿主/让位/挂载模式参考本地 Metis 工程 Modules/Charging（CSCoverSheetViewController
// hook 套装 + 窗口层挂载 + 通知栈让位 + 密码页摘卡），内容换血为「当前充电策略」：
// hero 策略动作 + 电量环（目标刻度）+ 参数网格 + 恢复条件 + 锁屏启动临时充满按钮。
//
// 数据通路（零网络、零 App 依赖）：
//   读 —— jbroot("var/mobile/ChargeLimiter/saver_state.plist") 镜像：daemon root 写、
//         chmod 0644、内容 diff 后落盘并广播 com.chargelimiter.policystate；
//         本进程 1s tick 兜底重读。电池实时值（电量/温度/健康）IOKit 直读（Metis 同款）。
//   写 —— com.chargelimiter.saveraction notify（state=1 启动临时充满 / 2 取消），
//         与 CLThermalSim 的 thermalapply 通道同款 notify 命令模式；daemon 处理后
//         镜像回传（按钮 2s 内回显，超时判守护未响应并还原）。
//
// 交互安全面：
//   - 卡片容器重写 hitTest：仅按钮条命中，其余区域返回 nil 穿透锁屏手势
//     （容器 userInteractionEnabled=NO 会让整个子树收不到触摸，故用 hitTest 裁剪）。
//   - 启动临时充满 = 两击确认（3s 倒计时，超时还原）+ 震动反馈；取消为安全方向单点。
//   - daemon 不在场 / charging_saver_enabled 关 / 未插电 → 整卡不显示（回退安全）。
//
// 并发模型（防卡死基线）：hook 回调全部主线程；IOKit 注册表读数走串行后台队列，
// 主线程只做 UI；无锁无跨线程等待；drawRect 前置 nil 守卫。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <libroot/libroot.h>
#import <mach-o/dyld.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>

static NSString * const CLSaverMirrorNotifyName = @"com.chargelimiter.policystate";
static NSString * const CLSaverActionNotifyName = @"com.chargelimiter.saveraction";
static const CGFloat CLSaverCardDesignWidth = 344.0;
static const CGFloat CLSaverCardDesignHeight = 334.0;
static const NSTimeInterval CLSaverEchoTimeoutSeconds = 2.0;
static const NSTimeInterval CLSaverConfirmWindowSeconds = 3.0;

// 诊断日志：syslog 可见（idevicesyslog grep CLSaver）。状态翻转才打，避免刷屏。
static void CLSaverLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[CLSaver] %@", message);
}

#pragma mark - 电池直读（Metis 同款原语）

// jbroot 前缀解析（SpringBoard 注入进程专用）：优先从 dyld 镜像列表里扫描 tweak
// 自身 dylib 路径推导——tweak 必装在 <jbroot>/Library/MobileSubstrate/DynamicLibraries/
// 下，截取 "/.jbroot-XXXX" 前缀即可（utils.mm resolveJbRootFromSelfExe 同款模式）。
// libroot_dyn_jbrootpath 只作兜底：App/daemon 由 roothide launchd 拉起自带解析上下文，
// 注入进程（SpringBoard）里 libroot 动态解析的可用性没有保证，不能作为唯一通路。
static NSString *CLSaverJbRootFromImagePath(NSString *path) {
    if (![path.lastPathComponent isEqualToString:@"CLChargingSaver.dylib"]) return nil;
    NSRange marker = [path rangeOfString:@"/.jbroot-"];
    if (marker.location == NSNotFound) return nil;

    NSUInteger identifierStart = NSMaxRange(marker);
    NSRange componentEnd = [path rangeOfString:@"/" options:0
                                         range:NSMakeRange(identifierStart, path.length - identifierStart)];
    if (componentEnd.location == NSNotFound || componentEnd.location == identifierStart) return nil;
    return [path substringToIndex:componentEnd.location];
}

static NSString *CLSaverJbRootPath(void) {
    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *name = _dyld_get_image_name(i);
            if (!name) continue;
            cached = CLSaverJbRootFromImagePath([NSString stringWithUTF8String:name]);
            if (cached) break;
        }
        if (cached.length == 0) {
            char resolved[PATH_MAX];
            const char *r = libroot_dyn_jbrootpath("/", resolved);
            if (r) {
                NSString *root = [NSString stringWithUTF8String:r];
                root = [root stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                while (root.length > 1 && [root hasSuffix:@"/"]) {
                    root = [root substringToIndex:root.length - 1];
                }
                if ([root rangeOfString:@"/.jbroot-"].location != NSNotFound) cached = root;
            }
        }
        CLSaverLog(@"state=jbroot-resolve result=%@", cached ?: @"FAILED");
    });
    return cached;
}

static NSDictionary *CLSaverReadBattery(void) {
    // 仅探测电池服务节点；注册表读数只发生在采样队列，绝不进 SpringBoard 布局路径。
    for (NSString *name in @[@"AppleSmartBattery", @"AppleARMPMUPowerSource", @"IOPMPowerSource"]) {
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(name.UTF8String));
        if (!service) continue;
        CFMutableDictionaryRef properties = NULL;
        kern_return_t result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
        IOObjectRelease(service);
        if (result == KERN_SUCCESS && properties) {
            NSDictionary *values = CFBridgingRelease(properties);
            if ([values isKindOfClass:[NSDictionary class]] &&
                (values[@"ExternalConnected"] || values[@"CurrentCapacity"] || values[@"Voltage"])) {
                return values;
            }
        }
    }
    return @{};
}

static BOOL CLSaverDeviceLocked(void) {
    // SBLockScreenManager isUILocked：签名探测式调用（Metis 同款）。签名探测本身
    // 失败（类/方法缺失）→ fail-open 按「已锁」处理：宿主是 cover sheet 已隐含锁屏
    // 语境；isUILocked 显式返回 NO 时才按未锁拦截。
    Class cls = NSClassFromString(@"SBLockScreenManager");
    SEL shared = NSSelectorFromString(@"sharedInstance"), locked = NSSelectorFromString(@"isUILocked");
    NSMethodSignature *factory = [cls methodSignatureForSelector:shared];
    if (!factory || factory.numberOfArguments != 2 || strcmp(factory.methodReturnType, "@")) return YES;
    @try {
        id manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
        NSMethodSignature *signature = [manager methodSignatureForSelector:locked];
        if (!signature || signature.numberOfArguments != 2 ||
            (strcmp(signature.methodReturnType, "B") && strcmp(signature.methodReturnType, "c"))) return YES;
        return ((BOOL (*)(id, SEL))objc_msgSend)(manager, locked);
    } @catch (__unused NSException *exception) { return YES; }
}

// 私有 selector 读数：缺失（或签名不符）时返回 missingValue，存在时返回真实值。
// 门槛判据用它做 fail-open——iOS 版本差异导致的 selector 缺失不应让屏保永不显示。
static BOOL CLSaverBoolOrMissing(id object, NSString *name, BOOL missingValue) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 ||
        (strcmp(signature.methodReturnType, "B") && strcmp(signature.methodReturnType, "c"))) return missingValue;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) { return missingValue; }
}

#pragma mark - 策略文案映射（与 App CLHistoryPolicyStateLabel 同源语义）

@interface CLSaverStrategy : NSObject
@property (nonatomic, copy) NSString *heroTitle;      // 大字策略动作
@property (nonatomic, copy) NSString *heroSubtitle;   // 「当前策略 · …」
@property (nonatomic, copy) NSString *badgeTitle;     // 底部胶囊
@property (nonatomic, copy) NSString *recoveryNote;   // 底部恢复条件（右对齐）
@property (nonatomic, assign) BOOL warning;           // 停充/临时充满 → 橙色系
@end
@implementation CLSaverStrategy
@end

static CLSaverStrategy *CLSaverStrategyForMirror(NSDictionary *mirror) {
    CLSaverStrategy *s = [CLSaverStrategy new];
    NSString *state = [mirror isKindOfClass:[NSDictionary class]] ? (mirror[@"policy_state"] ?: @"battery") : @"battery";
    BOOL tempFull = mirror[@"temp_full_charge_active"] ? [mirror[@"temp_full_charge_active"] boolValue] : NO;
    NSInteger above = mirror[@"charge_above"] ? [mirror[@"charge_above"] integerValue] : 100;
    NSInteger below = mirror[@"charge_below"] ? [mirror[@"charge_below"] integerValue] : 20;
    if (tempFull) {
        s.heroTitle = @"临时充满中";
        s.heroSubtitle = @"当前策略 · 上限已临时解除";
        s.badgeTitle = @"临时充满中";
        s.recoveryNote = [NSString stringWithFormat:@"充满后自动恢复 %ld%%", (long)above];
        s.warning = YES;
        return s;
    }
    if ([state isEqualToString:@"charging"]) {
        s.heroTitle = @"正在充电";
        s.heroSubtitle = @"当前策略 · 插电即充";
        s.badgeTitle = @"正在充电";
        s.recoveryNote = [NSString stringWithFormat:@"到 %ld%% 自动停充", (long)above];
    } else if ([state isEqualToString:@"temp_paused"]) {
        float tempBelow = mirror[@"charge_temp_below"] ? [mirror[@"charge_temp_below"] floatValue] : 35.0;
        s.heroTitle = @"温控暂停";
        s.heroSubtitle = @"当前策略 · 温度达到上限";
        s.badgeTitle = @"温控暂停";
        s.recoveryNote = [NSString stringWithFormat:@"温度 ≤%.0f° 恢复充电", tempBelow];
        s.warning = YES;
    } else if ([state isEqualToString:@"hold"] || [state isEqualToString:@"hold_recharge"]) {
        NSInteger lower = mirror[@"hold_lower"] ? [mirror[@"hold_lower"] integerValue] : (above - 5);
        s.heroTitle = @"插电保持";
        s.heroSubtitle = @"当前策略 · 插电保持";
        s.badgeTitle = @"插电保持";
        s.recoveryNote = [NSString stringWithFormat:@"保持区间 %ld–%ld%%", (long)lower, (long)above];
    } else if ([state isEqualToString:@"stopped"] || [state isEqualToString:@"no_inflow"]) {
        s.heroTitle = @"已停充";
        s.heroSubtitle = @"当前策略 · 达到电量上限";
        s.badgeTitle = @"已停充";
        s.recoveryNote = [NSString stringWithFormat:@"低于 %ld%% 自动恢复充电", (long)below];
        s.warning = YES;
    } else {
        s.heroTitle = @"未充电";
        s.heroSubtitle = @"当前策略 · 等待充电";
        s.badgeTitle = @"未充电";
        s.recoveryNote = @"等待充电策略执行";
    }
    return s;
}

#pragma mark - 策略卡（ink = drawRect 文本/环/网格，cta = 真实可点按钮条）

typedef NS_ENUM(NSInteger, CLSaverButtonState) {
    CLSaverButtonReady,
    CLSaverButtonConfirming,
    CLSaverButtonActive,
    CLSaverButtonPending,
    CLSaverButtonNoResponse,
};

static UIColor *CLSaverGreen(void) { return [UIColor colorWithRed:0.44 green:0.93 blue:0.67 alpha:1]; }
static UIColor *CLSaverOrange(void) { return [UIColor colorWithRed:1.0 green:0.725 blue:0.35 alpha:1]; }

// 注册表读数类型守卫：AppleSmartBattery 字段应为 NSNumber；非数值类型一律兜底，
// 不走裸 intValue/intValue 转换（防未来固件字段类型变化的 unrecognized selector 闪退）。
static NSInteger CLSaverIntValue(id value, NSInteger fallback) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value integerValue];
    return fallback;
}
static double CLSaverDoubleValue(id value, double fallback) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value doubleValue];
    return fallback;
}

static BOOL CLSaverHasExternalPower(NSDictionary *battery) {
    if (CLSaverIntValue(battery[@"ExternalConnected"], 0) ||
        CLSaverIntValue(battery[@"ExternalChargeCapable"], 0) ||
        CLSaverIntValue(battery[@"IsCharging"], 0)) return YES;

    // 禁流时系统可能清零上述字段。沿用 daemon 的适配器判据，排除电池供电标记。
    id adapter = battery[@"AdapterDetails"];
    if (![adapter isKindOfClass:[NSDictionary class]]) return NO;
    id description = adapter[@"Description"];
    return [description isKindOfClass:[NSString class]] &&
        [description length] > 0 && ![description isEqualToString:@"batt"];
}

static void CLSaverText(NSString *text, CGRect rect, CGFloat size, UIFontWeight weight, UIColor *color, NSTextAlignment align) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = align;
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: style}];
}

@interface CLSaverCardInk : UIView
@property (nonatomic, strong) NSDictionary *mirror;
@property (nonatomic, strong) NSDictionary *battery;
@property (nonatomic, assign) BOOL confirming;
@end

@implementation CLSaverCardInk
- (void)drawRect:(CGRect)rect {
    NSDictionary *mirror = self.mirror;
    if (!mirror) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextScaleCTM(context, self.bounds.size.width / CLSaverCardDesignWidth, self.bounds.size.height / CLSaverCardDesignHeight);
    UIColor *white = UIColor.whiteColor;
    UIColor *muted = [white colorWithAlphaComponent:0.64];
    UIColor *dim = [white colorWithAlphaComponent:0.35];
    CLSaverStrategy *strategy = CLSaverStrategyForMirror(mirror);
    UIColor *accent = strategy.warning ? CLSaverOrange() : CLSaverGreen();

    BOOL tempFull = mirror[@"temp_full_charge_active"] ? [mirror[@"temp_full_charge_active"] boolValue] : NO;
    NSInteger above = mirror[@"charge_above"] ? [mirror[@"charge_above"] integerValue] : 100;
    NSInteger below = mirror[@"charge_below"] ? [mirror[@"charge_below"] integerValue] : 20;
    BOOL enableTemp = mirror[@"enable_temp"] ? [mirror[@"enable_temp"] boolValue] : NO;
    float tempAbove = mirror[@"charge_temp_above"] ? [mirror[@"charge_temp_above"] floatValue] : 40.0;

    int capacity = (int)CLSaverIntValue(self.battery[@"CurrentCapacity"], 0);
    float temperature = self.battery[@"Temperature"] ? ((float)CLSaverDoubleValue(self.battery[@"Temperature"], NAN) / 100.0) : NAN;
    double maxCap = CLSaverDoubleValue(self.battery[@"AppleRawMaxCapacity"], NAN);
    double designCap = CLSaverDoubleValue(self.battery[@"AppleRawDesignCapacity"], NAN);
    int cycleCount = (int)CLSaverIntValue(self.battery[@"CycleCount"], 0);

    CLSaverText(strategy.heroTitle, CGRectMake(17, 17, 242, 42), 30, UIFontWeightSemibold, white, NSTextAlignmentLeft);
    CLSaverText(strategy.heroSubtitle, CGRectMake(18, 61, 242, 17), 11, UIFontWeightSemibold, muted, NSTextAlignmentLeft);

    // 电量环：填充 = 电量比例；目标刻度 = 停充上限（临时充满时 100%）
    CGFloat ringTarget = tempFull ? 100.0 : (CGFloat)above;
    BOOL targetReached = capacity >= ringTarget;
    CGPoint center = CGPointMake(294, 49);
    CGFloat radius = 27;
    UIBezierPath *track = [UIBezierPath bezierPathWithArcCenter:center radius:radius startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES];
    track.lineWidth = 4.5;
    [[white colorWithAlphaComponent:0.13] setStroke];
    [track stroke];
    if (capacity > 0) {
        CGFloat fraction = MIN(capacity / 100.0, 1.0);
        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:center radius:radius startAngle:-M_PI_2
                                                             endAngle:-M_PI_2 + M_PI * 2 * fraction clockwise:YES];
        ring.lineWidth = 4.5;
        ring.lineCapStyle = kCGLineCapRound;
        [accent setStroke];
        [ring stroke];
    }
    // 目标刻度线：到达后用白色（与弧末端重合仍可辨），未到用目标色
    CGFloat tickAngle = -M_PI_2 + M_PI * 2 * (ringTarget / 100.0);
    CGPoint tickOuter = CGPointMake(center.x + cosf(tickAngle) * (radius + 3.5), center.y + sinf(tickAngle) * (radius + 3.5));
    CGPoint tickInner = CGPointMake(center.x + cosf(tickAngle) * (radius - 3.5), center.y + sinf(tickAngle) * (radius - 3.5));
    UIBezierPath *tick = [UIBezierPath bezierPath];
    [tick moveToPoint:tickInner];
    [tick addLineToPoint:tickOuter];
    tick.lineWidth = 2.4;
    tick.lineCapStyle = kCGLineCapRound;
    [targetReached ? UIColor.whiteColor : accent setStroke];
    [tick stroke];
    CLSaverText([NSString stringWithFormat:@"%d%%", capacity], CGRectMake(264, 39, 60, 22), 15, UIFontWeightBold, white, NSTextAlignmentCenter);
    CLSaverText([NSString stringWithFormat:@"目标 %ld%%", (long)ringTarget], CGRectMake(256, 85, 76, 15), 10, UIFontWeightSemibold, muted, NSTextAlignmentCenter);

    [[white colorWithAlphaComponent:0.1] setStroke];
    UIBezierPath *dividers = [UIBezierPath bezierPath];
    [dividers moveToPoint:CGPointMake(17, 112)];
    [dividers addLineToPoint:CGPointMake(327, 112)];
    [dividers moveToPoint:CGPointMake(17, 169)];
    [dividers addLineToPoint:CGPointMake(327, 169)];
    for (NSNumber *x in @[@120, @223]) {
        [dividers moveToPoint:CGPointMake(x.doubleValue, 112)];
        [dividers addLineToPoint:CGPointMake(x.doubleValue, 230)];
    }
    dividers.lineWidth = 0.35;
    [dividers stroke];

    NSArray *rowTitles = @[@"停充上限", @"开始充电", @"电池温度", @"温度控制", @"临时充满", @"电池健康"];
    NSString *tempText = isfinite(temperature) ? [NSString stringWithFormat:@"%.1f°C", temperature] : @"—";
    NSString *healthText = (isfinite(maxCap) && isfinite(designCap) && designCap > 0)
        ? [NSString stringWithFormat:@"%.0f%%", maxCap * 100.0 / designCap] : (cycleCount > 0 ? [NSString stringWithFormat:@"%ld 次", (long)cycleCount] : @"—");
    NSString *tempFullText = tempFull ? @"激活中" : (self.confirming ? @"确认中…" : @"未启用");
    NSArray *rowValues = @[
        [NSString stringWithFormat:@"%ld%%", (long)above],
        [NSString stringWithFormat:@"%ld%%", (long)below],
        tempText,
        enableTemp ? [NSString stringWithFormat:@"开 · %.0f°", tempAbove] : @"关",
        tempFullText,
        healthText,
    ];
    for (NSUInteger i = 0; i < 6; i++) {
        CGFloat x = (i % 3) == 0 ? 18 : ((i % 3) == 1 ? 133 : 236);
        CGFloat y = i < 3 ? 122 : 179;
        CLSaverText(rowTitles[i], CGRectMake(x, y, 86, 15), 10, UIFontWeightSemibold, muted, NSTextAlignmentLeft);
        UIColor *valueColor = white;
        if ([rowTitles[i] isEqualToString:@"临时充满"]) valueColor = (tempFull || self.confirming) ? CLSaverOrange() : dim;
        CLSaverText(rowValues[i], CGRectMake(x, y + 17, 92, 21), 15, UIFontWeightSemibold, valueColor, NSTextAlignmentLeft);
    }

    // 底部状态胶囊 + 恢复条件
    CGFloat badgeWidth = strategy.badgeTitle.length > 4 ? 80 : 69;
    CGRect badge = CGRectMake(17, 234, badgeWidth, 24);
    [[accent colorWithAlphaComponent:0.14] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:badge cornerRadius:11] fill];
    CLSaverText(strategy.badgeTitle, CGRectInset(badge, 4, 5), 11, UIFontWeightSemibold, accent, NSTextAlignmentCenter);
    CLSaverText(strategy.recoveryNote, CGRectMake(104, 239, 223, 17), 11, UIFontWeightMedium, muted, NSTextAlignmentRight);
    CGContextRestoreGState(context);
}
@end

@interface CLSaverCTAView : UIView
@property (nonatomic, assign) CLSaverButtonState ctaState;
@property (nonatomic, copy) NSString *readyTitle;
@property (nonatomic, assign) CGFloat confirmProgress; // 0..1 确认倒计时进度
@property (nonatomic, copy) void (^onTap)(CLSaverButtonState currentState);
@end

@implementation CLSaverCTAView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];
        self.layer.cornerRadius = 14;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}
- (void)handleTap:(UITapGestureRecognizer *)gesture {
    [self accessibilityActivate];
}
- (BOOL)accessibilityActivate {
    if (!self.onTap || self.ctaState == CLSaverButtonPending || self.ctaState == CLSaverButtonNoResponse) return NO;
    self.onTap(self.ctaState);
    return YES;
}
- (void)drawRect:(CGRect)rect {
    UIColor *green = CLSaverGreen();
    UIColor *orange = CLSaverOrange();
    NSString *text = @"";
    UIColor *color = green;
    UIColor *border = [green colorWithAlphaComponent:0.35];
    UIColor *fill = [green colorWithAlphaComponent:0.10];
    if (self.ctaState == CLSaverButtonReady) {
        text = self.readyTitle ?: @"⚡ 启动临时充满";
    } else if (self.ctaState == CLSaverButtonConfirming) {
        text = [NSString stringWithFormat:@"再点一次确认 · %.0f 秒内生效", CLSaverConfirmWindowSeconds];
        color = orange;
        border = [orange colorWithAlphaComponent:0.55];
        fill = [orange colorWithAlphaComponent:0.16];
    } else if (self.ctaState == CLSaverButtonActive) {
        text = @"取消临时充满";
        color = orange;
        border = [orange colorWithAlphaComponent:0.45];
        fill = [orange colorWithAlphaComponent:0.10];
    } else if (self.ctaState == CLSaverButtonPending) {
        text = @"已发送 · 等待守护确认…";
        color = [UIColor colorWithWhite:1 alpha:0.7];
        border = [UIColor colorWithWhite:1 alpha:0.2];
        fill = [UIColor colorWithWhite:1 alpha:0.05];
    } else {
        text = @"守护未响应 · 请检查 ChargeLimiter";
        color = [UIColor colorWithWhite:1 alpha:0.5];
        border = [UIColor colorWithWhite:1 alpha:0.12];
        fill = [UIColor colorWithWhite:1 alpha:0.04];
    }
    self.accessibilityLabel = text;
    self.layer.borderColor = border.CGColor;
    self.backgroundColor = fill;
    CGRect bounds = self.bounds;
    CGFloat scale = bounds.size.width / (CLSaverCardDesignWidth - 34.0);
    UIFont *font = [UIFont systemFontOfSize:14 * scale weight:UIFontWeightSemibold];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [text drawInRect:CGRectMake(8, (bounds.size.height - font.lineHeight) / 2, bounds.size.width - 16, ceil(font.lineHeight))
       withAttributes:@{NSFontAttributeName: font,
                        NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: style}];
    if (self.ctaState == CLSaverButtonConfirming) {
        // 确认倒计时进度条（底边）
        CGFloat progressWidth = bounds.size.width * MAX(0, MIN(self.confirmProgress, 1.0));
        CGRect bar = CGRectMake(0, bounds.size.height - 3, progressWidth, 3);
        [[orange colorWithAlphaComponent:0.8] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:1.5] fill];
    }
}
@end

@interface CLSaverCardView : UIView
@property (nonatomic, strong) CLSaverCardInk *ink;
@property (nonatomic, strong) CLSaverCTAView *cta;
@end

@implementation CLSaverCardView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 26;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
        self.backgroundColor = [UIColor colorWithRed:0.075 green:0.072 blue:0.095 alpha:0.88];
        self.ink = [[CLSaverCardInk alloc] initWithFrame:self.bounds];
        self.ink.backgroundColor = UIColor.clearColor;
        self.ink.contentMode = UIViewContentModeRedraw;
        self.ink.opaque = NO;
        self.ink.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:self.ink];
        self.cta = [[CLSaverCTAView alloc] initWithFrame:CGRectZero];
        [self addSubview:self.cta];
        // 容器必须可交互才能让 hitTest 裁剪生效（userInteractionEnabled=NO 会让整个
        // 子树收不到触摸）；非按钮区域由 hitTest 返回 nil 穿透锁屏手势。
        self.userInteractionEnabled = YES;
    }
    return self;
}
// 仅按钮条命中：其余区域返回 nil，触摸继续走锁屏系统手势（Metis 免触控语义的局部化）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled) return nil;
    return [self.cta hitTest:[self.cta convertPoint:point fromView:self] withEvent:event];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = self.bounds.size.width / CLSaverCardDesignWidth;
    self.ink.frame = self.bounds;
    CGFloat ctaX = 17.0 * scale;
    CGFloat ctaHeight = 44.0 * scale;
    self.cta.frame = CGRectMake(ctaX, self.bounds.size.height - ctaHeight - 15.0 * scale,
                                self.bounds.size.width - ctaX * 2, ctaHeight);
}
@end

#pragma mark - 运行时（宿主 hook + 采样 + 卡片生命周期）

@interface CLSaverRuntime : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIViewController *passcodeController;
@property (nonatomic, strong) CLSaverCardView *card;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSTimer *confirmTimer;
@property (nonatomic, assign) NSTimeInterval confirmDeadline;
@property (nonatomic, strong) dispatch_queue_t samplingQueue;
@property (nonatomic, strong) NSDictionary *mirror;              // saver_state.plist 内容
@property (nonatomic, assign) BOOL appeared;
@property (nonatomic, assign) BOOL displayOn;
@property (nonatomic, assign) BOOL sampling;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, assign) NSTimeInterval lastProbeTime;
@property (nonatomic, assign) NSInteger pendingAction;           // 0 无 / 1 启动 / 2 取消
@property (nonatomic, assign) NSTimeInterval pendingActionTime;
@property (nonatomic, assign) NSTimeInterval hintShownTime;      // 「守护未响应」提示起始时间
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lastGateReasons; // 门槛诊断去重
@property (nonatomic, copy) NSString *lastBatteryLogState;       // 电池采样诊断去重
@property (nonatomic, copy) NSString *lastMirrorLogState;        // 镜像状态诊断去重
@property (nonatomic, assign) int displayToken;
@property (nonatomic, assign) int lockToken;
@property (nonatomic, assign) int mirrorToken;
+ (instancetype)shared;
- (void)refresh;
- (void)layout;
- (void)stop;
- (void)reloadMirror;
- (void)sampleBattery;
@end

@implementation CLSaverRuntime

+ (instancetype)shared {
    static CLSaverRuntime *runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ runtime = [self new]; });
    return runtime;
}

- (instancetype)init {
    if ((self = [super init])) {
        _samplingQueue = dispatch_queue_create("com.chargelimiter.saver", DISPATCH_QUEUE_SERIAL);
        _displayOn = YES; _displayToken = -1; _lockToken = -1; _mirrorToken = -1;
        __weak typeof(self) weakSelf = self;
        if (notify_register_dispatch("com.apple.iokit.hid.displayStatus", &_displayToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) weakSelf.displayOn = state != 0;
            [weakSelf refresh];
        }) == NOTIFY_STATUS_OK) {
            uint64_t state = 0;
            if (notify_get_state(_displayToken, &state) == NOTIFY_STATUS_OK) _displayOn = state != 0;
        } else _displayToken = -1;
        if (notify_register_dispatch("com.apple.springboard.lockstate", &_lockToken, dispatch_get_main_queue(), ^(int token) {
            [weakSelf refresh];
        }) != NOTIFY_STATUS_OK) _lockToken = -1;
        if (notify_register_dispatch(CLSaverMirrorNotifyName.UTF8String, &_mirrorToken, dispatch_get_main_queue(), ^(int token) {
            [weakSelf reloadMirror];
            weakSelf.lastProbeTime = 0;
            [weakSelf refresh];
        }) != NOTIFY_STATUS_OK) _mirrorToken = -1;
        [self reloadMirror];
    }
    return self;
}

- (void)dealloc {
    [self.timer invalidate];
    [self.confirmTimer invalidate];
    if (_displayToken >= 0) notify_cancel(_displayToken);
    if (_lockToken >= 0) notify_cancel(_lockToken);
    if (_mirrorToken >= 0) notify_cancel(_mirrorToken);
}

#pragma mark 镜像读取与按钮回显

- (void)reloadMirror {
    NSString *jbRoot = CLSaverJbRootPath();
    if (jbRoot.length == 0) {
        CLSaverLog(@"state=mirror-resolve-failed");
        return;
    }
    NSString *path = [jbRoot stringByAppendingPathComponent:@"var/mobile/ChargeLimiter/saver_state.plist"];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    self.mirror = [dict isKindOfClass:[NSDictionary class]] ? dict : nil;
    BOOL exists = self.mirror != nil;
    BOOL daemonEnable = self.mirror[@"daemon_enable"] ? [self.mirror[@"daemon_enable"] boolValue] : NO;
    BOOL saverEnable = self.mirror[@"saver_enabled"] ? [self.mirror[@"saver_enabled"] boolValue] : NO;
    BOOL tempFull = self.mirror[@"temp_full_charge_active"] ? [self.mirror[@"temp_full_charge_active"] boolValue] : NO;
    NSString *state = [NSString stringWithFormat:@"exists=%d daemon=%d saver=%d tempfull=%d", exists, daemonEnable, saverEnable, tempFull];
    if (![state isEqualToString:self.lastMirrorLogState]) {
        self.lastMirrorLogState = state;
        CLSaverLog(@"state=mirror %@ path=%@", state, path);
    }
    [self resolvePendingEcho];
    [self refreshCardContent];
}

// 按钮命令回显闭环：daemon 2s 内经镜像回传即清除 pending；超时判「守护未响应」。
- (void)resolvePendingEcho {
    if (self.pendingAction == 0) return;
    BOOL armed = self.mirror[@"temp_full_charge_active"] ? [self.mirror[@"temp_full_charge_active"] boolValue] : NO;
    BOOL confirmed = (self.pendingAction == 1 && armed) || (self.pendingAction == 2 && !armed);
    if (self.mirror && confirmed) {
        self.pendingAction = 0;
        return;
    }
    if (self.pendingActionTime > 0 &&
        NSProcessInfo.processInfo.systemUptime - self.pendingActionTime > CLSaverEchoTimeoutSeconds) {
        self.pendingAction = 0;
        if (self.card) {
            self.hintShownTime = NSProcessInfo.processInfo.systemUptime;
        }
        return;
    }
}

- (BOOL)saverFeatureEnabled {
    if (!self.mirror) return NO; // 镜像不存在 = daemon 不在场，回退安全
    return [self.mirror[@"daemon_enable"] boolValue] && [self.mirror[@"saver_enabled"] boolValue];
}

#pragma mark 显示门槛（Metis canShow 同款判据 + 充电屏保自有开关）

- (BOOL)canShow {
    UIView *view = self.host.viewIfLoaded;
    if (!self.saverFeatureEnabled) return NO;
    BOOL enabled = self.appeared && self.displayOn && !self.passcodeController && view.window && !view.hidden &&
        view.bounds.size.height > view.bounds.size.width && CLSaverDeviceLocked();
    if (!enabled) {
        NSString *reason = self.passcodeController ? @"passcode" :
            (!self.appeared ? @"not-appeared" :
            (!self.displayOn ? @"display-off" :
            (!view.window ? @"no-window" :
            (view.bounds.size.height <= view.bounds.size.width ? @"landscape" : @"not-locked"))));
        [self logGateFlip:@"core" reason:reason];
        return NO;
    }
    // 私有 selector 门槛 fail-open：selector 在该 iOS 版本缺失时按「不阻塞」处理，
    // 只有真实存在且返回阻塞值时才隐藏（iOS 17 上缺失任何一个都会导致永不显示）。
    BOOL mainPage = CLSaverBoolOrMissing(self.host, @"_isMainPageShowing", YES);
    BOOL pageHidden = CLSaverBoolOrMissing(self.host, @"_isPageContentHidden", NO);
    BOOL contentAbove = CLSaverBoolOrMissing(self.host, @"hasContentAboveCoverSheet", NO);
    BOOL posterSwitcher = CLSaverBoolOrMissing(self.host, @"_isPresentingPosterSwitcher", NO);
    if (!mainPage || pageHidden || contentAbove || posterSwitcher) {
        NSString *reason = !mainPage ? @"not-main-page" :
            (pageHidden ? @"page-content-hidden" :
            (contentAbove ? @"content-above" : @"poster-switcher"));
        [self logGateFlip:@"cover" reason:reason];
        return NO;
    }
    [self logGatePass];
    return YES;
}

// 门槛诊断：同一原因只打一次（翻转才打），syslog 里 grep CLSaver 即可定位卡在哪一关。
- (void)logGateFlip:(NSString *)group reason:(NSString *)reason {
    if ([self.lastGateReasons[group] isEqualToString:reason]) return;
    if (!self.lastGateReasons) self.lastGateReasons = [NSMutableDictionary new];
    self.lastGateReasons[group] = reason;
    CLSaverLog(@"state=gate-blocked gate=%@ reason=%@ feature=%@", group, reason, self.saverFeatureEnabled ? @"yes" : @"no");
}

- (void)logGatePass {
    if (self.lastGateReasons.count == 0) return;
    [self.lastGateReasons removeAllObjects];
    CLSaverLog(@"state=gate-pass");
}

#pragma mark 刷新循环（1s tick，0.8s 采样节流，Metis 同款）

- (void)ensureTimer {
    if (self.timer) return;
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh];
    }];
    self.timer.tolerance = 0.15;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)refresh {
    if (![self canShow]) { [self stop]; return; }
    // 回显状态机的 1s 兜底驱动：daemon 广播（policystate notify）丢失或 daemon
    // 已死时，pending 超时判定与按钮还原不依赖 notify 到达（防按钮卡在「已发送」）
    [self resolvePendingEcho];
    [self refreshCardContent];
    if (self.sampling) return;
    NSTimeInterval probeTime = NSProcessInfo.processInfo.systemUptime;
    if (probeTime - self.lastProbeTime < 0.8) return;
    self.lastProbeTime = probeTime;
    [self sampleBattery];
}

- (void)sampleBattery {
    if (!self.saverFeatureEnabled) return;
    if (self.sampling) return;
    self.sampling = YES;
    NSUInteger generation = self.generation;
    dispatch_async(self.samplingQueue, ^{
        NSDictionary *battery = CLSaverReadBattery();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.sampling = NO;
            if (generation != self.generation || ![self canShow]) return;
            BOOL externalConnected = CLSaverHasExternalPower(battery);
            BOOL isCharging = CLSaverIntValue(battery[@"IsCharging"], 0) != 0;
            NSString *batteryState = [NSString stringWithFormat:@"connected=%d charging=%d capacity=%d",
                externalConnected, isCharging,
                (int)CLSaverIntValue(battery[@"CurrentCapacity"], 0)];
            if (![batteryState isEqualToString:self.lastBatteryLogState]) {
                self.lastBatteryLogState = batteryState;
                CLSaverLog(@"state=battery %@", batteryState);
            }
            // 充电屏保只在「已连接外部电源」的充电会话内显示；拔电即收卡
            if (!externalConnected) { [self stop]; return; }
            [self ensureTimer];
            if (!self.card) {
                self.card = [[CLSaverCardView alloc] initWithFrame:CGRectZero];
                __weak typeof(self) weakSelf = self;
                self.card.cta.onTap = ^(CLSaverButtonState currentState) {
                    [weakSelf handleCTATap:currentState];
                };
                // 挂到窗口层：深度合成锁屏的壁纸主体层会盖住 cover sheet 内部视图，
                // 窗口是保证在其之上的最低层（Metis 同款注释与结论）
                UIView *anchor = self.host.view.window ?: self.host.view;
                [anchor addSubview:self.card];
                CLSaverLog(@"state=card-attached anchor=%@", NSStringFromClass(anchor.class));
            }
            self.card.ink.battery = battery;
            [self layout];
            [self refreshCardContent];
        });
    });
}

- (void)refreshCardContent {
    if (!self.card) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    CLSaverButtonState state = CLSaverButtonReady;
    if (self.pendingAction != 0) {
        state = CLSaverButtonPending;
    } else if (self.hintShownTime > 0 && now - self.hintShownTime < 3.0) {
        state = CLSaverButtonNoResponse;
    } else if ([self.mirror[@"temp_full_charge_active"] boolValue]) {
        state = CLSaverButtonActive;
    } else if (now < self.confirmDeadline) {
        state = CLSaverButtonConfirming;
    }
    if (state != CLSaverButtonConfirming && self.confirmTimer) [self stopConfirmCountdown];

    self.card.ink.mirror = self.mirror;
    self.card.ink.confirming = state == CLSaverButtonConfirming;
    [self.card.ink setNeedsDisplay];

    NSInteger limit = CLSaverIntValue(self.mirror[@"charge_above"], 100);
    BOOL atLimit = [self.mirror[@"policy_reason"] isEqual:@"capacity_high"];
    self.card.cta.readyTitle = atLimit
        ? @"⚡ 启动临时充满 · 解除上限继续充电"
        : [NSString stringWithFormat:@"⚡ 启动临时充满 · 充满后自动恢复 %ld%%", (long)limit];
    self.card.cta.ctaState = state;
    [self.card.cta setNeedsDisplay];
}

#pragma mark 按钮命令（两击确认 + 触感 + notify 下发 + 回显闭环）

- (void)handleCTATap:(CLSaverButtonState)state {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    if (state == CLSaverButtonReady) {
        [self startConfirmCountdown];
        [haptic impactOccurred];
    } else if (state == CLSaverButtonConfirming) {
        BOOL confirmedInTime = NSProcessInfo.processInfo.systemUptime < self.confirmDeadline;
        [self stopConfirmCountdown];
        if (!confirmedInTime) {
            [self refreshCardContent];
            return;
        }
        UIImpactFeedbackGenerator *heavy = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [heavy impactOccurred];
        [self postSaverAction:1];
    } else if (state == CLSaverButtonActive) {
        // 取消是安全方向：单点直接下发
        [haptic impactOccurred];
        [self postSaverAction:2];
    }
}

- (void)startConfirmCountdown {
    [self stopConfirmCountdown];
    self.confirmDeadline = NSProcessInfo.processInfo.systemUptime + CLSaverConfirmWindowSeconds;
    self.card.cta.confirmProgress = 1.0;
    __weak typeof(self) weakSelf = self;
    self.confirmTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.card) { [timer invalidate]; return; }
        NSTimeInterval remaining = strongSelf.confirmDeadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) {
            [strongSelf stopConfirmCountdown];
            [strongSelf refreshCardContent];
            return;
        }
        strongSelf.card.cta.confirmProgress = remaining / CLSaverConfirmWindowSeconds;
        [strongSelf.card.cta setNeedsDisplay];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.confirmTimer forMode:NSRunLoopCommonModes];
    [self refreshCardContent];
}

- (void)stopConfirmCountdown {
    [self.confirmTimer invalidate];
    self.confirmTimer = nil;
    self.confirmDeadline = 0;
}

- (void)postSaverAction:(NSInteger)action {
    static int postToken = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(CLSaverActionNotifyName.UTF8String, &postToken);
    });
    notify_set_state(postToken, (uint64_t)action);
    notify_post(CLSaverActionNotifyName.UTF8String);
    CLSaverLog(@"state=action-posted action=%ld", (long)action);
    self.pendingAction = action;
    self.pendingActionTime = NSProcessInfo.processInfo.systemUptime;
    [self refreshCardContent];
}

#pragma mark 通知栈让位（Metis 有界扫描修剪版）

static BOOL CLSaverNotificationContentClass(NSString *name) {
    static NSSet<NSString *> *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ classes = [NSSet setWithArray:@[@"NCNotificationListCell",
        @"NCNotificationShortLookView", @"NCNotificationLongLookView",
        @"NotificationShortLookView", @"NotificationLongLookView"]]; });
    return [classes containsObject:name];
}

static void CLSaverScanNode(UIView *node, NSUInteger depth, NSUInteger *budget, UIView *windowRoot,
                            UIView **notificationHit) {
    if (*budget == 0 || depth > 16) return;
    if (node.hidden || node.alpha < 0.01f) return;
    (*budget)--;
    if (!*notificationHit) {
        for (Class cls = node.class; cls; cls = class_getSuperclass(cls)) {
            if (CLSaverNotificationContentClass(NSStringFromClass(cls))) {
                CGRect frame = [node convertRect:node.bounds toView:windowRoot];
                if (frame.size.width > 8 && frame.size.height > 8 && CGRectIntersectsRect(frame, windowRoot.bounds)) {
                    *notificationHit = node;
                }
                break;
            }
        }
    } else {
        // 已有命中：保留最靠上的（通知栈顶），卡片让位到栈上方
        for (Class cls = node.class; cls; cls = class_getSuperclass(cls)) {
            if (CLSaverNotificationContentClass(NSStringFromClass(cls))) {
                CGRect frame = [node convertRect:node.bounds toView:windowRoot];
                if (frame.size.width > 8 && frame.size.height > 8 && CGRectIntersectsRect(frame, windowRoot.bounds)) {
                    CGRect prev = [*notificationHit convertRect:(*notificationHit).bounds toView:windowRoot];
                    if (CGRectGetMinY(frame) < CGRectGetMinY(prev)) *notificationHit = node;
                }
                break;
            }
        }
    }
    for (UIView *child in node.subviews) {
        CLSaverScanNode(child, depth + 1, budget, windowRoot, notificationHit);
    }
}

// 返回通知栈在窗口坐标系的顶部 Y（无通知返回 CGFLOAT_MAX）
static CGFloat CLSaverCoverSheetNotificationTopY(UIViewController *host) {
    UIView *hostView = host.viewIfLoaded;
    UIView *window = hostView.window;
    if (!window) return CGFLOAT_MAX;
    UIView *hit = nil;
    NSUInteger budget = 1200;
    for (UIView *child in window.subviews) {
        CLSaverScanNode(child, 1, &budget, window, &hit);
    }
    if (!hit) return CGFLOAT_MAX;
    CGRect frame = [hit convertRect:hit.bounds toView:window];
    return CGRectGetMinY(frame);
}

#pragma mark 布局（Metis 同款：底部锚点 + 通知栈让位）

- (void)layout {
    UIView *host = self.host.viewIfLoaded;
    if (!host || !self.card) return;
    if (![self canShow]) { [self stop]; return; }
    CGFloat width = MIN(host.bounds.size.width - 32, 430);
    CGFloat height = width * CLSaverCardDesignHeight / CLSaverCardDesignWidth;
    CGFloat bottom = host.bounds.size.height - host.safeAreaInsets.bottom - 86;
    CGFloat notificationTop = CLSaverCoverSheetNotificationTopY(self.host);
    if (notificationTop < CGFLOAT_MAX) {
        // 通知栈在场：卡片上移到栈上方；放不下则隐藏但保持轮询
        CGFloat movedBottom = notificationTop - 12;
        if (movedBottom - height >= host.bounds.size.height * 0.35) bottom = movedBottom;
        else { [self.card removeFromSuperview]; self.card = nil; return; }
    }
    if (width < 250 || bottom - height < host.bounds.size.height * 0.35) {
        [self.card removeFromSuperview];
        self.card = nil;
        return;
    }
    CGRect rect = CGRectMake((host.bounds.size.width - width) / 2, bottom - height, width, height);
    UIView *parent = self.card.superview;
    self.card.frame = parent && parent != host ? [host convertRect:rect toView:parent] : rect;
    if (parent && parent.subviews.lastObject != self.card) [parent bringSubviewToFront:self.card];
}

#pragma mark 卡片生命周期

- (void)stop {
    if (self.card) {
        CLSaverLog(@"state=card-removed");
    }
    self.generation++;
    [self stopConfirmCountdown];
    [self.timer invalidate];
    self.timer = nil;
    [self.card removeFromSuperview];
    self.card = nil;
}

#pragma mark 宿主 hook 事件

- (void)hostDidAppear:(UIViewController *)controller {
    self.host = controller;
    self.appeared = YES;
    [self refresh];
}

- (void)hostWillDisappear:(UIViewController *)controller {
    if (self.host == controller) {
        self.appeared = NO;
        [self stop];
        self.host = nil;
    }
}

- (void)hostDidLayout:(UIViewController *)controller {
    if (self.host == controller) {
        [self layout];
        if (self.saverFeatureEnabled && !self.timer) [self refresh];
    }
}

- (void)hostScreenOff:(BOOL)off {
    self.displayOn = !off;
    if (self.host) { self.lastProbeTime = 0; [self refresh]; }
}

- (void)passcodeWillAppear:(UIViewController *)controller {
    // 密码键盘出现前撤销待发采样，键盘中途摘卡（Metis 同款时序）
    self.passcodeController = controller;
    [self stop];
}

- (void)passcodeDidDisappear:(UIViewController *)controller {
    if (self.passcodeController == controller) {
        self.passcodeController = nil;
        self.lastProbeTime = 0;
        [self refresh];
    }
}

@end

#pragma mark - Hook 安装（Metis MTChargingInstall 同款）

static void (*CLSaverOriginalAppear)(UIViewController *, SEL, BOOL);
static void (*CLSaverOriginalDisappear)(UIViewController *, SEL, BOOL);
static void (*CLSaverOriginalLayout)(UIViewController *, SEL);
static void (*CLSaverOriginalScreenOff)(UIViewController *, SEL, BOOL);
static void (*CLSaverOriginalContentAbove)(UIViewController *, SEL, BOOL);
static void (*CLSaverOriginalPageIndex)(UIViewController *, SEL, unsigned long long);
static void (*CLSaverOriginalPasscodeAppear)(UIViewController *, SEL, BOOL);
static void (*CLSaverOriginalPasscodeDisappear)(UIViewController *, SEL, BOOL);

static void CLSaverAppear(UIViewController *controller, SEL selector, BOOL animated) {
    CLSaverOriginalAppear(controller, selector, animated);
    [CLSaverRuntime.shared hostDidAppear:controller];
}
static void CLSaverDisappear(UIViewController *controller, SEL selector, BOOL animated) {
    [CLSaverRuntime.shared hostWillDisappear:controller];
    CLSaverOriginalDisappear(controller, selector, animated);
}
static void CLSaverLayout(UIViewController *controller, SEL selector) {
    CLSaverOriginalLayout(controller, selector);
    [CLSaverRuntime.shared hostDidLayout:controller];
}
static void CLSaverScreenOff(UIViewController *controller, SEL selector, BOOL off) {
    CLSaverOriginalScreenOff(controller, selector, off);
    [CLSaverRuntime.shared hostScreenOff:off];
}
static void CLSaverContentAbove(UIViewController *controller, SEL selector, BOOL above) {
    CLSaverOriginalContentAbove(controller, selector, above);
    if (CLSaverRuntime.shared.host == controller) {
        CLSaverRuntime.shared.lastProbeTime = 0;
        [CLSaverRuntime.shared refresh];
    }
}
static void CLSaverPageIndex(UIViewController *controller, SEL selector, unsigned long long index) {
    CLSaverOriginalPageIndex(controller, selector, index);
    if (CLSaverRuntime.shared.host == controller) {
        CLSaverRuntime.shared.lastProbeTime = 0;
        [CLSaverRuntime.shared refresh];
    }
}
static void CLSaverPasscodeAppear(UIViewController *controller, SEL selector, BOOL animated) {
    [CLSaverRuntime.shared passcodeWillAppear:controller];
    CLSaverOriginalPasscodeAppear(controller, selector, animated);
}
static void CLSaverPasscodeDisappear(UIViewController *controller, SEL selector, BOOL animated) {
    CLSaverOriginalPasscodeDisappear(controller, selector, animated);
    [CLSaverRuntime.shared passcodeDidDisappear:controller];
}

static BOOL CLSaverMethodSupported(Class cls, SEL selector, BOOL animated) {
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType, "v") || signature.numberOfArguments != (animated ? 3u : 2u)) return NO;
    if (!animated) return YES;
    const char *type = [signature getArgumentTypeAtIndex:2];
    return !strcmp(type, "B") || !strcmp(type, "c");
}

static void CLSaverInstall(void) {
    Class passcode = NSClassFromString(@"CSPasscodeViewController");
    SEL passcodeAppear = @selector(viewWillAppear:), passcodeDisappear = @selector(viewDidDisappear:);
    if (CLSaverMethodSupported(passcode, passcodeAppear, YES) &&
        CLSaverMethodSupported(passcode, passcodeDisappear, YES)) {
        MSHookMessageEx(passcode, passcodeAppear, (IMP)CLSaverPasscodeAppear, (IMP *)&CLSaverOriginalPasscodeAppear);
        MSHookMessageEx(passcode, passcodeDisappear, (IMP)CLSaverPasscodeDisappear, (IMP *)&CLSaverOriginalPasscodeDisappear);
    } else {
        CLSaverLog(@"state=passcode-hooks-unavailable");
    }
    Class cls = NSClassFromString(@"CSCoverSheetViewController");
    SEL appear = @selector(viewDidAppear:), disappear = @selector(viewWillDisappear:), layout = @selector(viewDidLayoutSubviews);
    if (!cls) {
        CLSaverLog(@"state=install-failed reason=cover-sheet-class-missing");
        return;
    }
    if (!CLSaverMethodSupported(cls, appear, YES) || !CLSaverMethodSupported(cls, disappear, YES) ||
        !CLSaverMethodSupported(cls, layout, NO)) {
        CLSaverLog(@"state=install-failed reason=hook-signature-mismatch");
        return; // hook 不可用：功能静默禁用，绝不影响锁屏
    }
    MSHookMessageEx(cls, appear, (IMP)CLSaverAppear, (IMP *)&CLSaverOriginalAppear);
    MSHookMessageEx(cls, disappear, (IMP)CLSaverDisappear, (IMP *)&CLSaverOriginalDisappear);
    MSHookMessageEx(cls, layout, (IMP)CLSaverLayout, (IMP *)&CLSaverOriginalLayout);
    SEL screenOff = NSSelectorFromString(@"setInScreenOffMode:");
    if (CLSaverMethodSupported(cls, screenOff, YES)) {
        MSHookMessageEx(cls, screenOff, (IMP)CLSaverScreenOff, (IMP *)&CLSaverOriginalScreenOff);
    }
    SEL contentAbove = NSSelectorFromString(@"_setHasContentAboveCoverSheet:");
    if (CLSaverMethodSupported(cls, contentAbove, YES)) {
        MSHookMessageEx(cls, contentAbove, (IMP)CLSaverContentAbove, (IMP *)&CLSaverOriginalContentAbove);
    }
    SEL pageIndex = NSSelectorFromString(@"setLastSettledPageIndex:");
    NSMethodSignature *pageSignature = [cls instanceMethodSignatureForSelector:pageIndex];
    if (pageSignature.numberOfArguments == 3 && !strcmp(pageSignature.methodReturnType, "v") &&
        !strcmp([pageSignature getArgumentTypeAtIndex:2], "Q")) {
        MSHookMessageEx(cls, pageIndex, (IMP)CLSaverPageIndex, (IMP *)&CLSaverOriginalPageIndex);
    }
    CLSaverLog(@"state=installed host=%@", NSStringFromClass(cls));
}

__attribute__((constructor)) static void CLSaverBootstrap(void) {
    CLSaverInstall();
}
