#import "CLSaverBattery.h"
#include <math.h>
#include <stdint.h>

static const double CLMinimumChargeCurrent = 50.0;
static const double CLMaximumEstimateMinutes = 1440.0;
static const double CLGaugeJitter = 3.0;

static double CLNumber(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NAN;
    double result = [value doubleValue];
    return isfinite(result) ? result : NAN;
}

static double CLNumberInRange(double value, double minimum, double maximum) {
    return value >= minimum && value <= maximum ? value : NAN;
}

static double CLBatteryNumber(NSDictionary *properties, NSDictionary *nested, NSString *key) {
    double value = CLNumber(properties[key]);
    return isfinite(value) ? value : CLNumber(nested[key]);
}

CLSaverBatteryMetrics CLSaverBatteryMetricsFromProperties(NSDictionary *properties) {
    id batteryData = properties[@"BatteryData"];
    NSDictionary *nested = [batteryData isKindOfClass:NSDictionary.class] ? batteryData : nil;
    double current = CLBatteryNumber(properties, nested, @"CurrentCapacity");
    double maximum = CLBatteryNumber(properties, nested, @"MaxCapacity");
    double rawCurrent = CLNumberInRange(CLBatteryNumber(properties, nested, @"AppleRawCurrentCapacity"), 0, 50000);
    double rawMaximum = CLNumberInRange(CLBatteryNumber(properties, nested, @"AppleRawMaxCapacity"), 200, 50000);
    double nominal = CLNumberInRange(CLBatteryNumber(properties, nested, @"NominalChargeCapacity"), 200, 50000);
    double design = CLNumberInRange(CLBatteryNumber(properties, nested, @"DesignCapacity"), 200, 50000);
    if (!isfinite(design)) {
        design = CLNumberInRange(CLBatteryNumber(properties, nested, @"AppleRawDesignCapacity"), 200, 50000);
    }
    if (maximum > 200 && maximum <= 50000 && current >= 0 && current <= maximum) {
        if (!isfinite(rawCurrent)) rawCurrent = current;
        if (!isfinite(rawMaximum)) rawMaximum = maximum;
    }

    NSNumber *currentValue = properties[@"InstantAmperage"];
    double milliamp = CLNumber(currentValue);
    if (!isfinite(milliamp)) {
        currentValue = properties[@"Amperage"];
        milliamp = CLNumber(currentValue);
    }
    // Some drivers expose signed current as an unsigned 32- or 64-bit value.
    if (milliamp >= (double)INT64_MAX) milliamp = currentValue.longLongValue;
    if (milliamp >= 2147483648.0 && milliamp <= 4294967295.0) milliamp = (int32_t)(uint32_t)milliamp;
    milliamp = CLNumberInRange(milliamp, -20000, 20000);
    double volts = CLNumberInRange(CLBatteryNumber(properties, nested, @"Voltage"), 2000, 20000) / 1000.0;

    double percent = maximum > 0 && current >= 0 && current <= maximum
        ? current * 100.0 / maximum : CLNumberInRange(current, 0, 100);
    if (!isfinite(percent) && rawMaximum > 0 && rawCurrent >= 0 && rawCurrent <= rawMaximum) {
        percent = rawCurrent * 100.0 / rawMaximum;
    }
    id chargingFlag = properties[@"IsCharging"];
    BOOL charging = [chargingFlag isKindOfClass:NSNumber.class]
        ? [chargingFlag boolValue] : milliamp >= CLMinimumChargeCurrent;
    id fullFlag = properties[@"FullyCharged"];
    BOOL full = percent >= 100 || ([fullFlag isKindOfClass:NSNumber.class] && [fullFlag boolValue]);
    NSInteger systemMinutes = -1;
    for (NSString *key in @[@"AvgTimeToFull", @"Time to Full Charge"]) {
        double minutes = CLBatteryNumber(properties, nested, key);
        if (minutes >= 1 && minutes <= CLMaximumEstimateMinutes) {
            systemMinutes = (NSInteger)ceil(minutes);
            break;
        }
    }

    double healthCapacity = isfinite(nominal) ? nominal : rawMaximum;
    return (CLSaverBatteryMetrics){
        .levelPercent = percent,
        .currentMilliampHours = rawCurrent,
        .maximumMilliampHours = isfinite(rawMaximum) ? rawMaximum : nominal,
        .currentMilliamp = milliamp,
        .voltage = volts,
        .watts = isfinite(volts) && isfinite(milliamp) ? fmax(0, volts * milliamp / 1000.0) : NAN,
        .celsius = CLNumberInRange(CLBatteryNumber(properties, nested, @"Temperature"), -2000, 10000) / 100.0,
        .healthPercent = CLNumberInRange(healthCapacity / design * 100.0, 1, 300),
        .cycleCount = CLNumberInRange(CLBatteryNumber(properties, nested, @"CycleCount"), 0, 100000),
        .systemMinutesToFull = systemMinutes,
        .charging = charging && !full,
        .fullyCharged = full,
    };
}

static NSInteger CLMinutesForCurrent(double remaining, double milliamp) {
    if (!isfinite(remaining) || remaining <= 0 || !isfinite(milliamp) || milliamp < CLMinimumChargeCurrent) return -1;
    double minutes = remaining / milliamp * 60.0;
    if (minutes > CLMaximumEstimateMinutes) return -1;
    return minutes >= 60.0 ? (NSInteger)llround(minutes / 5.0) * 5 : MAX(1, (NSInteger)ceil(minutes));
}

@interface CLSaverChargeEstimator ()
@property (nonatomic, readwrite) NSInteger minutesToTarget;
@property (nonatomic) NSInteger targetPercent;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *samples;
@property (nonatomic) NSTimeInterval taperStart;
@property (nonatomic) NSTimeInterval taperLast;
@end

@implementation CLSaverChargeEstimator
- (instancetype)init {
    if ((self = [super init])) {
        _samples = [NSMutableArray array];
        [self reset];
    }
    return self;
}

- (void)reset {
    self.minutesToTarget = -1;
    self.targetPercent = 0;
    self.taperStart = NAN;
    self.taperLast = NAN;
    [self.samples removeAllObjects];
}

- (double)observedCurrentAtTime:(NSTimeInterval)time {
    double origin = self.samples.firstObject[@"time"].doubleValue;
    double elapsed = time - origin;
    if (self.samples.count < 2 || elapsed < 20.0) return NAN;

    // As in Metis, fit the capacity slope across the window and cross-check it
    // against the integrated battery current to reject gauge recalibrations.
    double sumTime = 0, sumCapacity = 0, sumTimeSquared = 0, sumProduct = 0;
    double milliampSeconds = 0;
    NSDictionary<NSString *, NSNumber *> *previous = nil;
    for (NSDictionary<NSString *, NSNumber *> *sample in self.samples) {
        double offset = sample[@"time"].doubleValue - origin;
        double capacity = sample[@"capacity"].doubleValue;
        sumTime += offset;
        sumCapacity += capacity;
        sumTimeSquared += offset * offset;
        sumProduct += offset * capacity;
        if (previous) {
            double interval = sample[@"time"].doubleValue - previous[@"time"].doubleValue;
            milliampSeconds += (sample[@"milliamp"].doubleValue + previous[@"milliamp"].doubleValue) * 0.5 * interval;
        }
        previous = sample;
    }
    double count = self.samples.count;
    double denominator = count * sumTimeSquared - sumTime * sumTime;
    if (denominator <= 1e-6) return NAN;
    double slopeCurrent = (count * sumProduct - sumTime * sumCapacity) / denominator * 3600.0;
    double averageCurrent = milliampSeconds / elapsed;
    if (slopeCurrent < CLMinimumChargeCurrent || slopeCurrent < averageCurrent * 0.5 ||
        slopeCurrent > averageCurrent * 2.0) return NAN;
    return MIN(averageCurrent, slopeCurrent);
}

- (void)updateWithBattery:(CLSaverBatteryMetrics)battery
            targetPercent:(NSInteger)target
                   atTime:(NSTimeInterval)time {
    if (target != self.targetPercent) [self reset];
    if (!battery.charging || battery.fullyCharged || battery.levelPercent >= target || target <= 0 || target > 100) {
        [self reset];
        return;
    }
    self.targetPercent = target;

    // The controller's estimate covers a full charge, including taper. A
    // ChargeLimiter cutoff below 100% uses only the mAh needed for that cutoff.
    if (target == 100 && battery.systemMinutesToFull > 0) {
        self.minutesToTarget = battery.systemMinutesToFull;
        [self.samples removeAllObjects];
        return;
    }

    double capacity = battery.currentMilliampHours;
    double maximum = battery.maximumMilliampHours;
    double milliamp = battery.currentMilliamp;
    double remaining = maximum * target / 100.0 - capacity;
    if (!isfinite(remaining) || remaining <= 0) {
        // The raw counter can reach the cutoff ahead of the reported SOC that
        // drives ChargeLimiter's policy. Use that SOC until the cutoff is met.
        remaining = maximum * (target - battery.levelPercent) / 100.0;
    }
    if (!isfinite(time) || !isfinite(remaining) || remaining <= 0 ||
        !isfinite(milliamp) || milliamp < CLMinimumChargeCurrent) {
        [self.samples removeAllObjects];
        self.taperStart = NAN;
        self.taperLast = NAN;
        return; // Keep the last estimate through a temporary gap while charging.
    }

    BOOL taperCandidate = battery.levelPercent >= 90 && battery.voltage >= 4.1 && milliamp <= maximum * 0.15;
    if (!taperCandidate || !isfinite(self.taperStart) || time < self.taperLast || time - self.taperLast > 10) {
        self.taperStart = taperCandidate ? time : NAN;
    }
    self.taperLast = time;

    double estimateCurrent = milliamp;
    if (!isfinite(capacity) || (taperCandidate && time - self.taperStart >= 30)) {
        [self.samples removeAllObjects];
    } else {
        NSDictionary<NSString *, NSNumber *> *last = self.samples.lastObject;
        double interval = time - last[@"time"].doubleValue;
        if (last && interval >= 0 && interval < 0.8) return;
        double change = capacity - last[@"capacity"].doubleValue;
        if (last && (interval < 0 || interval > 10 || change < -CLGaugeJitter ||
                     change > 2.0 * milliamp * interval / 3600.0 + CLGaugeJitter)) {
            [self.samples removeAllObjects];
        }
        [self.samples addObject:@{@"time": @(time), @"capacity": @(capacity), @"milliamp": @(milliamp)}];
        while (time - self.samples.firstObject[@"time"].doubleValue > 120.0) {
            [self.samples removeObjectAtIndex:0];
        }
        double observedCurrent = [self observedCurrentAtTime:time];
        if (isfinite(observedCurrent)) estimateCurrent = observedCurrent;
    }
    NSInteger minutes = CLMinutesForCurrent(remaining, estimateCurrent);
    if (minutes <= 0) minutes = CLMinutesForCurrent(remaining, milliamp);
    if (minutes > 0) self.minutesToTarget = minutes;
}
@end
