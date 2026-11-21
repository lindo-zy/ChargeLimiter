#import "CLSaverBattery.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>

static void expect(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

static CLSaverBatteryMetrics fixture(void) {
    return CLSaverBatteryMetricsFromProperties(@{
        @"CurrentCapacity": @55, @"MaxCapacity": @100, @"Voltage": @4020,
        @"InstantAmperage": @2500, @"Amperage": @1000, @"IsCharging": @YES,
        @"AvgTimeToFull": @65535, @"TimeRemaining": @12,
        @"BatteryData": @{@"AppleRawCurrentCapacity": @2200, @"AppleRawMaxCapacity": @4000,
                          @"NominalChargeCapacity": @3600, @"DesignCapacity": @4000,
                          @"Temperature": @3320, @"CycleCount": @0, @"Time to Full Charge": @47},
    });
}

static void testBatteryReadings(void) {
    CLSaverBatteryMetrics battery = fixture();
    expect(battery.levelPercent == 55 && battery.currentMilliampHours == 2200 &&
           battery.maximumMilliampHours == 4000, @"Raw mAh and displayed SOC must remain distinct");
    expect(fabs(battery.watts - 10.05) < 0.01 && fabs(battery.celsius - 33.2) < 0.01,
           @"Instantaneous battery-side power and temperature must use the registry units");
    expect(battery.healthPercent == 90 && battery.cycleCount == 0,
           @"Health uses nominal/design and a zero cycle count is valid");
    expect(battery.systemMinutesToFull == 47, @"An invalid primary ETA must fall back to the second full-charge field");

    battery = CLSaverBatteryMetricsFromProperties(@{@"CurrentCapacity": @55, @"MaxCapacity": @100, @"TimeRemaining": @15});
    expect(isnan(battery.currentMilliampHours) && isnan(battery.maximumMilliampHours) &&
           isnan(battery.watts) && battery.systemMinutesToFull == -1,
           @"Percentage counters and ambiguous remaining-time fields cannot supply mAh or an ETA");
    battery = CLSaverBatteryMetricsFromProperties(@{@"CurrentCapacity": @2200, @"MaxCapacity": @4000,
                                                      @"Voltage": @4000, @"Amperage": @500});
    expect(battery.levelPercent == 55 && battery.maximumMilliampHours == 4000 &&
           battery.currentMilliampHours == 2200 && battery.watts == 2,
           @"A legacy mAh-scaled pair and averaged current are usable");
    for (NSNumber *wrapped in @[@((uint32_t)-500), @((uint64_t)-500)]) {
        battery = CLSaverBatteryMetricsFromProperties(@{@"Voltage": @4000, @"InstantAmperage": wrapped});
        expect(battery.currentMilliamp == -500 && battery.watts == 0 && !battery.charging,
               @"Unsigned discharge current cannot become charging power");
    }
}

static void testTargetAndPause(void) {
    CLSaverChargeEstimator *estimator = [CLSaverChargeEstimator new];
    CLSaverBatteryMetrics battery = fixture();
    [estimator updateWithBattery:battery targetPercent:80 atTime:1];
    expect(estimator.minutesToTarget == 24, @"The 80% target cannot inherit the system's 100% ETA");
    [estimator updateWithBattery:battery targetPercent:100 atTime:2];
    expect(estimator.minutesToTarget == 47, @"A 100% target must prefer the system ETA");
    battery.currentMilliamp = 20;
    [estimator updateWithBattery:battery targetPercent:80 atTime:3];
    expect(estimator.minutesToTarget == -1, @"A target change clears the previous estimate");
    battery.currentMilliamp = 2500;
    [estimator updateWithBattery:battery targetPercent:80 atTime:4];
    battery.currentMilliamp = NAN;
    [estimator updateWithBattery:battery targetPercent:80 atTime:5];
    expect(estimator.minutesToTarget == 24, @"A brief measurement gap holds the estimate while charging");
    battery.charging = NO;
    [estimator updateWithBattery:battery targetPercent:80 atTime:6];
    expect(estimator.minutesToTarget == -1, @"Pausing clears the estimate");
    battery.charging = YES;
    [estimator updateWithBattery:battery targetPercent:80 atTime:7];
    expect(estimator.minutesToTarget == -1, @"Resuming must not reuse the estimate from before a pause");

    battery.currentMilliamp = 2500;
    battery.levelPercent = 79;
    battery.currentMilliampHours = 3205;
    [estimator updateWithBattery:battery targetPercent:80 atTime:8];
    expect(estimator.minutesToTarget == 1, @"Reported SOC is used when the raw counter reaches the limit early");
    battery.levelPercent = 80;
    [estimator updateWithBattery:battery targetPercent:80 atTime:9];
    expect(estimator.minutesToTarget == -1, @"Reaching the charge limit clears the estimate");
    battery.fullyCharged = YES;
    [estimator updateWithBattery:battery targetPercent:100 atTime:10];
    expect(estimator.minutesToTarget == -1, @"A battery marked full cannot show a system ETA");
}

static void testObservedRate(void) {
    CLSaverChargeEstimator *estimator = [CLSaverChargeEstimator new];
    CLSaverBatteryMetrics battery = fixture();
    battery.currentMilliamp = 1000;
    battery.levelPercent = 50;
    for (int second = 0; second <= 30; second++) {
        battery.currentMilliampHours = 2000 + second / 6.0; // Gauge slope: 600 mA.
        [estimator updateWithBattery:battery targetPercent:80 atTime:second];
        if (second == 0) expect(estimator.minutesToTarget == 70, @"First sample uses the instantaneous rate");
    }
    expect(estimator.minutesToTarget == 120, @"A mature, consistent window uses the observed rate");
    [estimator updateWithBattery:battery targetPercent:80 atTime:30.3];
    expect(estimator.minutesToTarget == 120, @"A duplicate sample must not replace the window estimate");
    battery.currentMilliampHours = 2200;
    [estimator updateWithBattery:battery targetPercent:80 atTime:31];
    expect(estimator.minutesToTarget == 60, @"A capacity jump restarts the window");
    for (int second = 32; second <= 55; second++) {
        battery.currentMilliampHours = 2200 + (second - 31) / 20.0; // Implausibly slow versus 1000 mA.
        [estimator updateWithBattery:battery targetPercent:80 atTime:second];
    }
    expect(estimator.minutesToTarget == 60, @"A slope inconsistent with current is rejected");
}

int main(void) {
    @autoreleasepool {
        testBatteryReadings();
        testTargetAndPause();
        testObservedRate();
    }
    return 0;
}
