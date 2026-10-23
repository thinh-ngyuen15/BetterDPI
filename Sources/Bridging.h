// Private interfaces used by BetterDPI.
// CGS display modes and CGVirtualDisplay are linked from CoreGraphics; the
// functions under "Private system controls" are implemented in Private.m.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - CGS display modes

// 212-byte mode record returned by CGSGetDisplayModeDescriptionOfLength.
// width/height are in points; density is 2.0 for HiDPI modes.
typedef struct {
    uint32_t mode;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t dc2[42];
    uint16_t dc3;
    uint16_t freq;
    uint8_t  dc4[16];
    float    density;
} CGSDisplayModeDescription;

extern void CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int *nModes);
extern void CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display, int idx,
                                                 CGSDisplayModeDescription *mode, int length);
extern void CGSGetCurrentDisplayMode(CGDirectDisplayID display, int *modeNum);
extern CGError CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display, int modeNum);

// Variable refresh rate (ProMotion, Adaptive-Sync) for a CGS mode index, via SkyLight's
// SLSIsDisplayModeVRR / SLSGetDisplayModeMinRefreshRate (Private.m). Returns NO for a fixed-rate
// mode or when unavailable; *minRefresh is the lowest rate the mode may drop to, 0 when unknown.
BOOL BDDisplayModeIsVariable(CGDirectDisplayID display, int modeNum, float *minRefresh);

#pragma mark - CGVirtualDisplay

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@end

#pragma mark - Private system controls (Private.m)

// Night Shift (CoreBrightness CBBlueLightClient). Return NO when unavailable.
BOOL BDNightShiftGet(BOOL *enabled, float *strength);
BOOL BDNightShiftSetEnabled(BOOL enabled);
BOOL BDNightShiftSetStrength(float strength);   // 0...1

// True Tone (CoreBrightness CBTrueToneClient).
BOOL BDTrueToneGet(BOOL *enabled);
BOOL BDTrueToneSetEnabled(BOOL enabled);

// Dark Mode (SkyLight SLS*AppearanceThemeLegacy). Get returns -1 when unavailable.
int BDDarkModeGet(void);
BOOL BDDarkModeSet(BOOL dark);

// Core Animation backdrop layer and CAFilter, created by name ("Overlay dimming and compositor filter layer").
CALayer *BDMakeBackdropLayer(void);
id BDMakeCAFilter(NSString *type);
