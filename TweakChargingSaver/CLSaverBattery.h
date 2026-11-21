#import <Foundation/Foundation.h>

typedef struct {
    double levelPercent;
    double currentMilliampHours;
    double maximumMilliampHours;
    double currentMilliamp;
    double voltage;
    double watts;
    double celsius;
    double healthPercent;
    double cycleCount;
    NSInteger systemMinutesToFull;
    BOOL charging;
    BOOL fullyCharged;
} CLSaverBatteryMetrics;

CLSaverBatteryMetrics CLSaverBatteryMetricsFromProperties(NSDictionary *properties);

@interface CLSaverChargeEstimator : NSObject
@property (nonatomic, readonly) NSInteger minutesToTarget;
- (void)updateWithBattery:(CLSaverBatteryMetrics)battery
            targetPercent:(NSInteger)target
                   atTime:(NSTimeInterval)time;
- (void)reset;
@end
