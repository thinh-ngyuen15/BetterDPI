// Private macOS interfaces, loaded at runtime so the app still launches if one
// disappears in a future macOS release.
#import "Bridging.h"
#include <dlfcn.h>
#include <objc/message.h>

typedef struct { int hour; int minute; } BDTime;
typedef struct { BDTime fromTime; BDTime toTime; } BDSchedule;
typedef struct {
    BOOL active;
    BOOL enabled;
    BOOL sunSchedulePermitted;
    int mode;
    BDSchedule schedule;
    unsigned long long disableFlags;
    BOOL available;
} BDBlueLightStatus;

static id client(NSString *className) {
    static NSMutableDictionary *clients;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
        clients = [NSMutableDictionary dictionary];
    });
    @synchronized (clients) {
        if (!clients[className]) {
            Class cls = NSClassFromString(className);
            if (!cls) return nil;
            clients[className] = [[cls alloc] init];
        }
        return clients[className];
    }
}

BOOL BDNightShiftGet(BOOL *enabled, float *strength) {
    id c = client(@"CBBlueLightClient");
    if (!c || ![c respondsToSelector:@selector(getBlueLightStatus:)]) return NO;
    BDBlueLightStatus status = {0};
    if (!((BOOL (*)(id, SEL, BDBlueLightStatus *))objc_msgSend)(c, @selector(getBlueLightStatus:), &status)) return NO;
    if (!status.available) return NO;
    if (enabled) *enabled = status.enabled;
    if (strength) {
        float s = 0;
        ((BOOL (*)(id, SEL, float *))objc_msgSend)(c, @selector(getStrength:), &s);
        *strength = s;
    }
    return YES;
}

BOOL BDNightShiftSetEnabled(BOOL enabled) {
    id c = client(@"CBBlueLightClient");
    if (!c) return NO;
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(c, @selector(setEnabled:), enabled);
}

BOOL BDNightShiftSetStrength(float strength) {
    id c = client(@"CBBlueLightClient");
    if (!c) return NO;
    return ((BOOL (*)(id, SEL, float, BOOL))objc_msgSend)(c, @selector(setStrength:commit:), strength, YES);
}

BOOL BDTrueToneGet(BOOL *enabled) {
    id c = client(@"CBTrueToneClient");
    if (!c || ![c respondsToSelector:@selector(supported)]) return NO;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(c, @selector(supported))) return NO;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(c, @selector(available))) return NO;
    if (enabled) *enabled = ((BOOL (*)(id, SEL))objc_msgSend)(c, @selector(enabled));
    return YES;
}

BOOL BDTrueToneSetEnabled(BOOL enabled) {
    id c = client(@"CBTrueToneClient");
    if (!c) return NO;
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(c, @selector(setEnabled:), enabled);
}

static void *skyLight(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    });
    return handle;
}

int BDDarkModeGet(void) {
    BOOL (*get)(void) = dlsym(skyLight(), "SLSGetAppearanceThemeLegacy");
    return get ? (get() ? 1 : 0) : -1;
}

BOOL BDDarkModeSet(BOOL dark) {
    void (*set)(BOOL) = dlsym(skyLight(), "SLSSetAppearanceThemeLegacy");
    if (!set) return NO;
    set(dark);
    return YES;
}

CALayer *BDMakeBackdropLayer(void) {
    Class cls = NSClassFromString(@"CABackdropLayer");
    if (!cls) return nil;
    CALayer *layer = [cls new];
    // Let the window server filter whatever is behind the window.
    for (NSString *key in @[@"windowServerAware", @"allowsInPlaceFiltering"]) {
        @try { [layer setValue:@YES forKey:key]; } @catch (__unused NSException *e) {}
    }
    return layer;
}

id BDMakeCAFilter(NSString *type) {
    Class cls = NSClassFromString(@"CAFilter");
    if (!cls || ![cls respondsToSelector:@selector(filterWithType:)]) return nil;
    return ((id (*)(id, SEL, NSString *))objc_msgSend)(cls, @selector(filterWithType:), type);
}

#pragma mark - Variable refresh rate

static void *skyLightSymbol(const char *name) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    });
    return handle ? dlsym(handle, name) : NULL;
}

BOOL BDDisplayModeIsVariable(CGDirectDisplayID display, int modeNum, float *minRefresh) {
    static bool (*isVRR)(CGDirectDisplayID, int);
    static CGError (*getMin)(CGDirectDisplayID, int, float *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isVRR = skyLightSymbol("SLSIsDisplayModeVRR");
        getMin = skyLightSymbol("SLSGetDisplayModeMinRefreshRate");
    });
    if (minRefresh) *minRefresh = 0;
    if (!isVRR || !isVRR(display, modeNum)) return NO;
    float min = 0;
    if (minRefresh && getMin && getMin(display, modeNum, &min) == kCGErrorSuccess) *minRefresh = min;
    return YES;
}
