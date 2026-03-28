// dsscan.m - Terminal scanner interface for Brother DS-720D via TWAIN
//
// Build: make
// Usage: ./dsscan                     (interactive mode)
//        ./dsscan --scan              (scan with current settings)
//        ./dsscan --help              (show help)

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <TWAIN/TWAIN.h>
#import <Quartz/Quartz.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <signal.h>
#import <objc/runtime.h>

// ============================================================================
// Constants
// ============================================================================

#define DS_NAME "Brother DS-720D TWAIN"
#define AVSCAN_PLIST @"/Library/Image Capture/TWAIN Data Sources/DS-720D.ds/Versions/A/avscan.plist"
#define DS_KEY @"DS-720D"
#define DEFAULT_OUTPUT_DIR [@"~/Documents/Scans" stringByExpandingTildeInPath]

// ImageType values for avscan.plist
typedef enum {
    IMAGE_TYPE_BW    = 0,
    IMAGE_TYPE_GRAY  = 4,
    IMAGE_TYPE_AUTO  = 8,
    IMAGE_TYPE_COLOR = 12,
} ImageTypeValue;

// ScanSource values
typedef enum {
    SCAN_SOURCE_SIMPLEX = 0,
    SCAN_SOURCE_DUPLEX  = 1,
} ScanSourceValue;

// Output format
typedef enum {
    FORMAT_PDF  = 0,
    FORMAT_TIFF = 1,
    FORMAT_JPEG = 2,
    FORMAT_PNG  = 3,
} OutputFormat;

// ============================================================================
// Scan Settings
// ============================================================================

typedef struct {
    ImageTypeValue colorMode;
    int            dpi;          // DPI for current color mode
    ScanSourceValue scanSource;
    OutputFormat   format;
    char           outputDir[1024];
} ScanSettings;

static ScanSettings gSettings = {
    .colorMode  = IMAGE_TYPE_COLOR,
    .dpi        = 300,
    .scanSource = SCAN_SOURCE_DUPLEX,
    .format     = FORMAT_PDF,
    .outputDir  = {0},
};

// ============================================================================
// TWAIN State
// ============================================================================

static TW_IDENTITY gAppIdentity;
static TW_IDENTITY gDSIdentity;
static int gTwainState = 1; // 1=pre, 2=DSM open, 3=DS open, 4=enabled, 5+=transfer
static BOOL gTransferReady = NO;
static BOOL gScanDone = NO;
static NSMutableArray *gScannedImages = nil; // Array of NSImage/file paths

// ============================================================================
// DS-720D Driver Crash Workaround
// ============================================================================
// The DS-720D TWAIN driver has a bug: after scanning completes, its background
// thread ([DS720DDS nextJob]) calls [DialogBoxController closeTransportWindow],
// which tries to close/animate an NSWindow off the main thread, causing SIGABRT.
//
// Fix: method-swizzle closeTransportWindow to be a no-op. This is safe because
// we _exit() after saving output anyway, so the leaked window doesn't matter.
// We also install SIGABRT handler as a belt-and-suspenders backup.

static volatile int gScanExitCode = 1; // Set to 0 after output is saved

static void driverCrashExceptionHandler(NSException *exception) {
    (void)exception;
    _exit(gScanExitCode);
}

static void driverCrashSignalHandler(int sig) {
    (void)sig;
    _exit(gScanExitCode);
}

// Thread-safe replacement for [DialogBoxController closeTransportWindow]
// The original crashes because it closes an NSWindow from a background thread.
// We dispatch to the main thread instead.
static IMP gOriginalCloseTransportWindow = NULL;

static void safe_closeTransportWindow(id self, SEL _cmd) {
    if ([NSThread isMainThread]) {
        if (gOriginalCloseTransportWindow) {
            ((void (*)(id, SEL))gOriginalCloseTransportWindow)(self, _cmd);
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gOriginalCloseTransportWindow) {
                ((void (*)(id, SEL))gOriginalCloseTransportWindow)(self, _cmd);
            }
        });
    }
}

static void installDriverCrashWorkarounds(void) {
    // Swizzle the crashing method to dispatch to main thread
    Class cls = NSClassFromString(@"DialogBoxController");
    if (cls) {
        SEL sel = NSSelectorFromString(@"closeTransportWindow");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            gOriginalCloseTransportWindow =
                method_setImplementation(m, (IMP)safe_closeTransportWindow);
        }
    }

    // Backup: catch SIGABRT in case there are other crash paths
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = driverCrashSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGABRT, &sa, NULL);

    NSSetUncaughtExceptionHandler(driverCrashExceptionHandler);
}

// ============================================================================
// Forward Declarations
// ============================================================================

static void initSettings(void);
static void loadSettingsFromPlist(void);
static void writeSettingsToPlist(void);
static const char *colorModeName(ImageTypeValue mode);
static const char *formatName(OutputFormat fmt);
static const char *scanSourceName(ScanSourceValue src);

static BOOL twainOpenDSM(void);
static BOOL twainFindDS(void);
static BOOL twainOpenDS(void);
static BOOL twainSetCapabilities(void);
static BOOL twainEnableDS(void);
static BOOL twainTransferImages(void);
static void twainDisableDS(void);
static void twainCloseDS(void);
static void twainCloseDSM(void);
static void twainCleanup(void);

static BOOL performScan(NSString *outputPath);
static NSString *generateOutputPath(void);
static BOOL savePDF(NSArray *imagePaths, NSString *outputPath);

static void showUI(void);
static void runInteractive(void);

// ============================================================================
// TWAIN Handle Helpers (Mac: TW_HANDLE = char**)
// ============================================================================

static TW_HANDLE twainAllocHandle(size_t size) {
    char **h = (char **)malloc(sizeof(char *));
    if (h) {
        *h = (char *)calloc(1, size);
        if (!*h) { free(h); return NULL; }
    }
    return (TW_HANDLE)h;
}

static void twainFreeHandle(TW_HANDLE h) {
    if (h) {
        if (*h) free(*h);
        free(h);
    }
}

static void *twainLockHandle(TW_HANDLE h) {
    return h ? *h : NULL;
}

// Mac Pascal string helpers
static void setTWStr32(TW_STR32 dest, const char *src) {
    size_t len = strlen(src);
    if (len > 32) len = 32;
    dest[0] = (unsigned char)len;
    memcpy(dest + 1, src, len);
    if (len < 33) dest[len + 1] = 0;
}

static void getTWStr32(const TW_STR32 src, char *dest, size_t destSize) {
    unsigned char len = src[0];
    if (len > 32) len = 32;
    if (len >= destSize) len = (unsigned char)(destSize - 1);
    memcpy(dest, src + 1, len);
    dest[len] = 0;
}

// TW_FIX32 helpers
static TW_FIX32 floatToFix32(double f) {
    TW_FIX32 fix;
    TW_INT32 val = (TW_INT32)(f * 65536.0 + 0.5);
    fix.Whole = (TW_INT16)(val >> 16);
    fix.Frac = (TW_UINT16)(val & 0xFFFF);
    return fix;
}

static double fix32ToFloat(TW_FIX32 fix) {
    return (double)fix.Whole + (double)fix.Frac / 65536.0;
}

// ============================================================================
// Settings Management
// ============================================================================

static void initSettings(void) {
    NSString *dir = DEFAULT_OUTPUT_DIR;
    strlcpy(gSettings.outputDir, [dir UTF8String], sizeof(gSettings.outputDir));

    // Create output directory if needed
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    loadSettingsFromPlist();
}

static void loadSettingsFromPlist(void) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:AVSCAN_PLIST];
    NSDictionary *ds = plist[DS_KEY];
    if (!ds) return;

    NSNumber *imageType = ds[@"ImageType"];
    if (imageType) gSettings.colorMode = (ImageTypeValue)[imageType intValue];

    NSNumber *scanSource = ds[@"ScanSource"];
    if (scanSource) gSettings.scanSource = (ScanSourceValue)[scanSource intValue];

    // DPI depends on color mode
    switch (gSettings.colorMode) {
        case IMAGE_TYPE_BW:
            gSettings.dpi = [ds[@"BWRes"] intValue] ?: 200;
            break;
        case IMAGE_TYPE_GRAY:
            gSettings.dpi = [ds[@"GrayRes"] intValue] ?: 200;
            break;
        case IMAGE_TYPE_COLOR:
        case IMAGE_TYPE_AUTO:
        default:
            gSettings.dpi = [ds[@"ColorRes"] intValue] ?: 300;
            break;
    }
}

static void writeSettingsToPlist(void) {
    NSMutableDictionary *plist = [[NSMutableDictionary alloc]
        initWithContentsOfFile:AVSCAN_PLIST];
    if (!plist) {
        fprintf(stderr, "Error: Cannot read %s\n", [AVSCAN_PLIST UTF8String]);
        return;
    }

    NSMutableDictionary *ds = [plist[DS_KEY] mutableCopy];
    if (!ds) {
        fprintf(stderr, "Error: No DS-720D key in plist\n");
        return;
    }

    ds[@"ImageType"] = @(gSettings.colorMode);
    ds[@"ScanSource"] = @(gSettings.scanSource);

    // Set DPI for the appropriate mode
    switch (gSettings.colorMode) {
        case IMAGE_TYPE_BW:
            ds[@"BWRes"] = @(gSettings.dpi);
            break;
        case IMAGE_TYPE_GRAY:
            ds[@"GrayRes"] = @(gSettings.dpi);
            break;
        case IMAGE_TYPE_COLOR:
        case IMAGE_TYPE_AUTO:
        default:
            ds[@"ColorRes"] = @(gSettings.dpi);
            break;
    }

    plist[DS_KEY] = ds;
    [plist writeToFile:AVSCAN_PLIST atomically:YES];
}

static const char *colorModeName(ImageTypeValue mode) {
    switch (mode) {
        case IMAGE_TYPE_BW:    return "B&W";
        case IMAGE_TYPE_GRAY:  return "Gray";
        case IMAGE_TYPE_COLOR: return "Color";
        case IMAGE_TYPE_AUTO:  return "Auto";
        default:               return "Unknown";
    }
}

static const char *formatName(OutputFormat fmt) {
    switch (fmt) {
        case FORMAT_PDF:  return "PDF";
        case FORMAT_TIFF: return "TIFF";
        case FORMAT_JPEG: return "JPEG";
        case FORMAT_PNG:  return "PNG";
        default:          return "Unknown";
    }
}

static const char *scanSourceName(ScanSourceValue src) {
    switch (src) {
        case SCAN_SOURCE_SIMPLEX: return "Simplex";
        case SCAN_SOURCE_DUPLEX:  return "Duplex";
        default:                  return "Unknown";
    }
}

static const char *formatExtension(OutputFormat fmt) {
    switch (fmt) {
        case FORMAT_PDF:  return "pdf";
        case FORMAT_TIFF: return "tiff";
        case FORMAT_JPEG: return "jpg";
        case FORMAT_PNG:  return "png";
        default:          return "dat";
    }
}

// ============================================================================
// TWAIN Operations
// ============================================================================

static TW_UINT16 callDSM(pTW_IDENTITY pDest, TW_UINT32 DG,
                          TW_UINT16 DAT, TW_UINT16 MSG, TW_MEMREF pData) {
    return DSM_Entry(&gAppIdentity, pDest, DG, DAT, MSG, pData);
}

// Get TWAIN status condition code after a failure
static TW_UINT16 twainGetStatus(pTW_IDENTITY pDest) {
    TW_STATUS status;
    memset(&status, 0, sizeof(status));
    TW_UINT16 rc = DSM_Entry(&gAppIdentity, pDest,
                              1, 0x0008, 0x0001, (TW_MEMREF)&status);
    // DG_CONTROL, DAT_STATUS, MSG_GET
    if (rc == 0) return status.ConditionCode;
    return 0xFFFF;
}

// Hidden window handle for TWAIN (some DSMs require non-NULL parent)
static NSWindow *gHiddenWindow = nil;

static BOOL twainOpenDSM(void) {
    if (gTwainState >= 2) return YES;

    // Create a hidden window - TWAIN DSM on Mac may need a window reference
    if (!gHiddenWindow) {
        gHiddenWindow = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 1, 1)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        [gHiddenWindow setReleasedWhenClosed:NO];
    }

    // Set up application identity
    memset(&gAppIdentity, 0, sizeof(gAppIdentity));
    gAppIdentity.Id = 0;
    gAppIdentity.Version.MajorNum = 1;
    gAppIdentity.Version.MinorNum = 0;
    gAppIdentity.Version.Language = 0; // TWLG_ENGLISH
    gAppIdentity.Version.Country = 1;  // TWCY_USA
    setTWStr32(gAppIdentity.Version.Info, "1.0");
    gAppIdentity.ProtocolMajor = 2; // TWON_PROTOCOLMAJOR
    gAppIdentity.ProtocolMinor = 4; // TWON_PROTOCOLMINOR
    gAppIdentity.SupportedGroups = 0x07; // DG_CONTROL | DG_IMAGE | DG_AUDIO
    setTWStr32(gAppIdentity.Manufacturer, "dsscan");
    setTWStr32(gAppIdentity.ProductFamily, "dsscan");
    setTWStr32(gAppIdentity.ProductName, "dsscan CLI");

    // Try with window handle first, fall back to NULL
    TW_MEMREF hParent = (TW_MEMREF)(__bridge void *)gHiddenWindow;
    TW_UINT16 rc = DSM_Entry(&gAppIdentity, NULL,
                              1, // DG_CONTROL
                              0x0004, // DAT_PARENT
                              0x0301, // MSG_OPENDSM
                              hParent);

    if (rc != 0) {
        // Try with NULL parent
        rc = DSM_Entry(&gAppIdentity, NULL, 1, 0x0004, 0x0301, NULL);
    }

    if (rc != 0) { // TWRC_SUCCESS
        fprintf(stderr, "Error: Failed to open TWAIN DSM (rc=%d)\n", rc);
        return NO;
    }

    gTwainState = 2;
    return YES;
}

static BOOL twainFindDS(void) {
    if (gTwainState < 2) return NO;

    memset(&gDSIdentity, 0, sizeof(gDSIdentity));

    // Enumerate data sources, looking for the DS-720D
    TW_UINT16 rc = callDSM(NULL, 1, 0x0003, 0x0004, (TW_MEMREF)&gDSIdentity);
    // DG_CONTROL, DAT_IDENTITY, MSG_GETFIRST

    int dsCount = 0;
    while (rc == 0) { // TWRC_SUCCESS
        dsCount++;

        // Try Pascal string (Mac TWAIN) and C string interpretations
        char pascalName[64] = {0};
        getTWStr32(gDSIdentity.ProductName, pascalName, sizeof(pascalName));
        char cName[36] = {0};
        memcpy(cName, gDSIdentity.ProductName, 34);
        cName[34] = 0;

        if (strstr(pascalName, "DS-720") || strstr(cName, "DS-720") ||
            strstr(pascalName, "Brother") || strstr(cName, "Brother")) {
            char *name = strlen(pascalName) > 0 ? pascalName : cName;
            fprintf(stderr, "Found: %s\n", name);
            return YES;
        }

        rc = callDSM(NULL, 1, 0x0003, 0x0005, (TW_MEMREF)&gDSIdentity);
        // DG_CONTROL, DAT_IDENTITY, MSG_GETNEXT
    }

    if (dsCount == 0) {
        fprintf(stderr, "Error: No TWAIN data sources found.\n");
        fprintf(stderr, "  Check that DS-720D.ds exists in /Library/Image Capture/TWAIN Data Sources/\n");
    } else {
        fprintf(stderr, "Error: DS-720D not found among %d source(s).\n", dsCount);
    }
    return NO;
}

static BOOL twainOpenDS(void) {
    if (gTwainState < 2) return NO;
    if (gTwainState >= 3) return YES;

    TW_UINT16 rc = callDSM(NULL, 1, 0x0003, 0x0401, (TW_MEMREF)&gDSIdentity);
    // DG_CONTROL, DAT_IDENTITY, MSG_OPENDS

    if (rc != 0) {
        TW_UINT16 cc = twainGetStatus(NULL);
        fprintf(stderr, "Error: Failed to open data source (rc=%d, cc=%d)\n", rc, cc);
        // Condition codes: 3=NODS, 4=MAXCONNECTIONS, 5=OPERATIONERROR,
        //   11=SEQERROR, 12=BADDEST, 23=CHECKDEVICEONLINE
        if (cc == 23) {
            fprintf(stderr, "  Scanner appears to be offline. Check USB connection.\n");
        } else if (cc == 4) {
            fprintf(stderr, "  Scanner may be in use by another application.\n");
        } else if (cc == 5) {
            fprintf(stderr, "  Operation error - scanner driver may have an issue.\n");
            fprintf(stderr, "  Try: Close DSmobileCapture if open, unplug/replug scanner.\n");
        }
        return NO;
    }

    gTwainState = 3;
    return YES;
}

static BOOL twainSetOneValueCap(TW_UINT16 cap, TW_UINT16 itemType, TW_UINT32 value) {
    TW_CAPABILITY twCap;
    twCap.Cap = cap;
    twCap.ConType = 0x0005; // TWON_ONEVALUE
    twCap.hContainer = twainAllocHandle(sizeof(TW_ONEVALUE));

    if (!twCap.hContainer) return NO;

    TW_ONEVALUE *pVal = (TW_ONEVALUE *)twainLockHandle(twCap.hContainer);
    pVal->ItemType = itemType;
    pVal->Item = value;

    TW_UINT16 rc = callDSM(&gDSIdentity, 1, 0x0001, 0x0006, (TW_MEMREF)&twCap);
    // DG_CONTROL, DAT_CAPABILITY, MSG_SET

    twainFreeHandle(twCap.hContainer);
    return (rc == 0); // TWRC_SUCCESS
}

static BOOL twainSetFixedCap(TW_UINT16 cap, double value) {
    TW_FIX32 fix = floatToFix32(value);
    TW_UINT32 fixVal;
    memcpy(&fixVal, &fix, sizeof(fixVal));
    return twainSetOneValueCap(cap, 0x0007, fixVal); // TWTY_FIX32
}

static BOOL twainSetCapabilities(void) {
    if (gTwainState < 3) return NO;

    BOOL ok = YES;

    // ICAP_PIXELTYPE (0x0101)
    TW_UINT16 pixelType;
    switch (gSettings.colorMode) {
        case IMAGE_TYPE_BW:    pixelType = 0; break; // TWPT_BW
        case IMAGE_TYPE_GRAY:  pixelType = 1; break; // TWPT_GRAY
        case IMAGE_TYPE_COLOR:
        case IMAGE_TYPE_AUTO:
        default:               pixelType = 2; break; // TWPT_RGB
    }
    if (!twainSetOneValueCap(0x0101, 0x0004, pixelType)) { // TWTY_UINT16
        fprintf(stderr, "Warning: Could not set pixel type\n");
    }

    // ICAP_XRESOLUTION (0x1118) and ICAP_YRESOLUTION (0x1119)
    if (!twainSetFixedCap(0x1118, (double)gSettings.dpi)) {
        fprintf(stderr, "Warning: Could not set X resolution\n");
    }
    if (!twainSetFixedCap(0x1119, (double)gSettings.dpi)) {
        fprintf(stderr, "Warning: Could not set Y resolution\n");
    }

    // CAP_FEEDERENABLED (0x1002) - always enable feeder (sheet-fed scanner)
    twainSetOneValueCap(0x1002, 0x0006, 1); // TWTY_BOOL, TRUE

    // CAP_DUPLEXENABLED (0x1013)
    TW_UINT16 duplex = (gSettings.scanSource == SCAN_SOURCE_DUPLEX) ? 1 : 0;
    if (!twainSetOneValueCap(0x1013, 0x0006, duplex)) { // TWTY_BOOL
        fprintf(stderr, "Warning: Could not set duplex mode\n");
    }

    // CAP_XFERCOUNT (0x0001) - scan all pages (-1)
    twainSetOneValueCap(0x0001, 0x0003, (TW_UINT32)-1); // TWTY_INT16

    // ICAP_XFERMECH (0x0103) - use native transfer
    // (DS-720D may not support memory transfer)
    twainSetOneValueCap(0x0103, 0x0004, 0); // TWSX_NATIVE

    return ok;
}

static BOOL twainEnableDS(void) {
    if (gTwainState < 3 || gTwainState >= 4) return NO;

    TW_USERINTERFACE ui;
    ui.ShowUI = 0;   // FALSE - headless
    ui.ModalUI = 0;  // FALSE
    ui.hParent = NULL;

    TW_UINT16 rc = callDSM(&gDSIdentity, 1, 0x0009, 0x0502, (TW_MEMREF)&ui);
    // DG_CONTROL, DAT_USERINTERFACE, MSG_ENABLEDS

    if (rc != 0 && rc != 2) { // TWRC_SUCCESS or TWRC_CHECKSTATUS
        TW_UINT16 cc = twainGetStatus(&gDSIdentity);
        fprintf(stderr, "Error: Failed to enable data source (rc=%d, cc=%d)\n", rc, cc);
        if (cc == 11) fprintf(stderr, "  Sequence error - DS may be in wrong state\n");
        if (cc == 5)  fprintf(stderr, "  Operation error\n");
        return NO;
    }

    gTwainState = 4;
    return YES;
}

static BOOL twainTransferOneImage(NSString *tempDir, int pageNum) {
    // Get image info first
    TW_IMAGEINFO imageInfo;
    memset(&imageInfo, 0, sizeof(imageInfo));

    TW_UINT16 rc = callDSM(&gDSIdentity, 2, 0x0101, 0x0001, (TW_MEMREF)&imageInfo);
    // DG_IMAGE, DAT_IMAGEINFO, MSG_GET

    if (rc != 0) {
        fprintf(stderr, "Warning: Could not get image info (rc=%d)\n", rc);
    } else {
        double xRes = fix32ToFloat(imageInfo.XResolution);
        double yRes = fix32ToFloat(imageInfo.YResolution);
        fprintf(stderr, "  Page %d: %dx%d pixels, %.0fx%.0f DPI, %d bpp, %d spp\n",
                pageNum,
                imageInfo.ImageWidth, imageInfo.ImageLength,
                xRes, yRes,
                imageInfo.BitsPerPixel,
                imageInfo.SamplesPerPixel);
    }

    NSString *filePath = [tempDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"page_%04d.tiff", pageNum]];

    // Use memory-based transfer for reliability
    // First, get the preferred memory layout
    TW_SETUPMEMXFER memSetup;
    memset(&memSetup, 0, sizeof(memSetup));
    rc = callDSM(&gDSIdentity, 1, 0x0006, 0x0001, (TW_MEMREF)&memSetup);
    // DG_CONTROL, DAT_SETUPMEMXFER, MSG_GET

    TW_UINT32 bufSize = 0;
    if (rc == 0) {
        bufSize = memSetup.Preferred;
    } else {
        bufSize = 256 * 1024; // Default 256KB
    }

    // Allocate buffer for memory transfer
    unsigned char *buffer = (unsigned char *)malloc(bufSize);
    if (!buffer) {
        fprintf(stderr, "Error: Could not allocate transfer buffer\n");
        return NO;
    }

    // Collect all strips into a single image buffer
    int width = imageInfo.ImageWidth > 0 ? imageInfo.ImageWidth : 0;
    int height = imageInfo.ImageLength > 0 ? imageInfo.ImageLength : 0;
    int bpp = imageInfo.BitsPerPixel > 0 ? imageInfo.BitsPerPixel : 8;
    int spp = imageInfo.SamplesPerPixel > 0 ? imageInfo.SamplesPerPixel : 1;

    NSMutableData *imageData = [NSMutableData data];
    TW_UINT32 actualBytesPerRow = 0;
    int totalRows = 0;

    // Transfer loop - get data strip by strip
    BOOL transferDone = NO;
    while (!transferDone) {
        TW_IMAGEMEMXFER memXfer;
        memset(&memXfer, 0, sizeof(memXfer));
        memXfer.Memory.Flags = 0x0001 | 0x0004; // TWMF_APPOWNS | TWMF_POINTER
        memXfer.Memory.Length = bufSize;
        memXfer.Memory.TheMem = (TW_MEMREF)buffer;

        rc = callDSM(&gDSIdentity, 2, 0x0103, 0x0001, (TW_MEMREF)&memXfer);
        // DG_IMAGE, DAT_IMAGEMEMXFER, MSG_GET

        if (rc == 0 || rc == 6) { // TWRC_SUCCESS or TWRC_XFERDONE
            // Append this strip's data
            [imageData appendBytes:buffer length:memXfer.BytesWritten];

            if (actualBytesPerRow == 0 && memXfer.BytesPerRow > 0) {
                actualBytesPerRow = memXfer.BytesPerRow;
            }
            totalRows += memXfer.Rows;

            if (rc == 6) { // TWRC_XFERDONE
                transferDone = YES;
            }
        } else {
            fprintf(stderr, "  Memory transfer error rc=%d at row %d\n", rc, totalRows);
            transferDone = YES;
        }
    }

    free(buffer);

    if ([imageData length] == 0) {
        fprintf(stderr, "  No image data received\n");
        return NO;
    }

    // Debug: fprintf(stderr, "  Received %lu bytes, %d rows\n",
    //         (unsigned long)[imageData length], totalRows);

    // Update dimensions from actual transfer data if image info was incomplete
    if (width == 0 && actualBytesPerRow > 0) {
        width = (int)(actualBytesPerRow * 8 / bpp);
    }
    if (height == 0 && totalRows > 0) {
        height = totalRows;
    }
    if (actualBytesPerRow == 0 && width > 0) {
        actualBytesPerRow = (width * bpp + 7) / 8;
    }

    // Create NSBitmapImageRep from the collected data
    unsigned char *rawBytes = (unsigned char *)[imageData mutableBytes];

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:&rawBytes
                      pixelsWide:width
                      pixelsHigh:height
                   bitsPerSample:8
                 samplesPerPixel:spp
                        hasAlpha:NO
                        isPlanar:NO
                  colorSpaceName:(spp >= 3 ?
                      NSCalibratedRGBColorSpace : NSCalibratedWhiteColorSpace)
                     bytesPerRow:actualBytesPerRow
                    bitsPerPixel:bpp];

    if (!rep) {
        fprintf(stderr, "  Could not create image rep (w=%d h=%d bpp=%d spp=%d bpr=%u)\n",
                width, height, bpp, spp, actualBytesPerRow);
        return NO;
    }

    // Set resolution
    double xRes = fix32ToFloat(imageInfo.XResolution);
    double yRes = fix32ToFloat(imageInfo.YResolution);
    if (xRes > 0 && yRes > 0) {
        NSSize size = NSMakeSize(width * 72.0 / xRes, height * 72.0 / yRes);
        [rep setSize:size];
    }

    NSData *tiffData = [rep TIFFRepresentation];
    if (!tiffData) {
        fprintf(stderr, "  Could not generate TIFF data\n");
        return NO;
    }

    [tiffData writeToFile:filePath atomically:YES];
    [gScannedImages addObject:filePath];
    fprintf(stderr, "  Saved page %d (%lu bytes)\n", pageNum, (unsigned long)[tiffData length]);

    return YES;
}

static BOOL twainTransferImages(void) {
    if (gTwainState < 5) return NO;

    NSString *tempDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"dsscan_temp"];

    // Clean and create temp directory
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tempDir error:nil];
    [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES
                   attributes:nil error:nil];

    gScannedImages = [NSMutableArray array];
    int pageNum = 1;
    BOOL morePages = YES;

    @try {
        while (morePages) {
            fprintf(stderr, "Transferring page %d...\n", pageNum);

            BOOL transferred = twainTransferOneImage(tempDir, pageNum);
            if (!transferred) {
                fprintf(stderr, "  Transfer failed, stopping.\n");
                break;
            }

            // End the current transfer and check for more
            TW_PENDINGXFERS pending;
            memset(&pending, 0, sizeof(pending));

            TW_UINT16 rc = callDSM(&gDSIdentity, 1, 0x0005, 0x0701, (TW_MEMREF)&pending);
            // DG_CONTROL, DAT_PENDINGXFERS, MSG_ENDXFER

            if (rc != 0) {
                fprintf(stderr, "  ENDXFER rc=%d, stopping.\n", rc);
                break;
            }

            // pending.Count == 0 means done, 0xFFFF means unknown/continue
            if (pending.Count == 0) {
                morePages = NO;
            } else {
                pageNum++;
            }
        }
    } @catch (NSException *exception) {
        // The DS-720D driver has a bug where it tries to close a window
        // from a background thread after scanning, causing a crash.
        // We catch the exception since our data is already transferred.
        fprintf(stderr, "  (DS driver cleanup exception caught - scan data is OK)\n");
    }

    return [gScannedImages count] > 0;
}

static void twainDisableDS(void) {
    if (gTwainState < 4) return;

    @try {
        TW_USERINTERFACE ui;
        ui.ShowUI = 0;
        ui.ModalUI = 0;
        ui.hParent = NULL;

        callDSM(&gDSIdentity, 1, 0x0009, 0x0501, (TW_MEMREF)&ui);
        // DG_CONTROL, DAT_USERINTERFACE, MSG_DISABLEDS
    } @catch (NSException *e) {
        // DS driver may throw during cleanup
    }

    gTwainState = 3;
}

static void twainCloseDS(void) {
    if (gTwainState < 3) return;

    @try {
        callDSM(NULL, 1, 0x0003, 0x0402, (TW_MEMREF)&gDSIdentity);
        // DG_CONTROL, DAT_IDENTITY, MSG_CLOSEDS
    } @catch (NSException *e) {
        // DS driver may throw during cleanup
    }

    gTwainState = 2;
}

static void twainCloseDSM(void) {
    if (gTwainState < 2) return;

    @try {
        DSM_Entry(&gAppIdentity, NULL, 1, 0x0004, 0x0302, NULL);
        // DG_CONTROL, DAT_PARENT, MSG_CLOSEDSM
    } @catch (NSException *e) {
        // Ignore
    }

    gTwainState = 1;
}

static void twainCleanup(void) {
    @try {
        if (gTwainState >= 4) twainDisableDS();
        if (gTwainState >= 3) twainCloseDS();
        if (gTwainState >= 2) twainCloseDSM();
    } @catch (NSException *e) {
        // DS-720D driver bug: tries to close window from background thread
        gTwainState = 1;
    }
}

// ============================================================================
// Scan Orchestration
// ============================================================================

@interface ScanDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSString *outputPath;
@property (assign) BOOL scanSucceeded;
@property (assign) BOOL scanFinished;
@end

@implementation ScanDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Run the scan on the main thread (required for TWAIN)
    [self performSelector:@selector(runScan) withObject:nil afterDelay:0.1];
}

- (void)runScan {
    self.scanSucceeded = NO;

    // Write settings to plist (DS reads these)
    writeSettingsToPlist();

    fprintf(stderr, "Opening TWAIN...\n");
    if (!twainOpenDSM()) goto done;
    fprintf(stderr, "Finding scanner...\n");
    if (!twainFindDS()) goto done;
    fprintf(stderr, "Opening scanner...\n");
    if (!twainOpenDS()) goto done;
    // Install crash workarounds now that the driver is loaded
    installDriverCrashWorkarounds();
    fprintf(stderr, "Setting capabilities...\n");
    twainSetCapabilities();
    fprintf(stderr, "Starting scan...\n");
    if (!twainEnableDS()) goto done;

    // After enabling the DS headless, we need to wait for the scanner
    // to be ready. We'll poll using a timer.
    gTransferReady = NO;
    gScanDone = NO;

    // Start polling timer
    [NSTimer scheduledTimerWithTimeInterval:0.1
                                     target:self
                                   selector:@selector(pollTwain:)
                                   userInfo:nil
                                    repeats:YES];
    return;

done:
    twainCleanup();
    self.scanFinished = YES;
    [NSApp stop:nil];
    // Post a dummy event to unblock the run loop
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0]
             atStart:YES];
}

- (void)pollTwain:(NSTimer *)timer {
    static int pollCount = 0;
    pollCount++;

    // Process any pending events through TWAIN
    // On Mac, we need to check if the DS has signaled readiness

    // Try to get image info - if it succeeds, data is ready
    TW_IMAGEINFO imageInfo;
    memset(&imageInfo, 0, sizeof(imageInfo));
    TW_UINT16 rc = callDSM(&gDSIdentity, 2, 0x0101, 0x0001, (TW_MEMREF)&imageInfo);
    // DG_IMAGE, DAT_IMAGEINFO, MSG_GET

    if (rc == 0) { // TWRC_SUCCESS - data ready!
        [timer invalidate];
        gTwainState = 5;
        fprintf(stderr, "Scanner ready, transferring...\n");

        BOOL hasImages = twainTransferImages();

        if (hasImages) {
            fprintf(stderr, "Scanned %lu page(s)\n", (unsigned long)[gScannedImages count]);
            if ([self saveOutput]) {
                // Mark success so crash handlers know output is saved
                gScanExitCode = 0;
            }
        }

        // Exit immediately - TWAIN cleanup is skipped but the OS
        // reclaims all resources. This also avoids the driver crash
        // if it hasn't happened yet.
        fflush(stderr);
        fflush(stdout);
        _exit(gScanExitCode);
        return;
    }

    // Timeout after 60 seconds (600 polls at 0.1s)
    if (pollCount > 600) {
        fprintf(stderr, "Error: Scan timeout - no data received after 60s\n");
        fprintf(stderr, "  (Is paper loaded in the scanner?)\n");
        [timer invalidate];
        twainCleanup();
        self.scanFinished = YES;
        [NSApp stop:nil];
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                            location:NSZeroPoint
                                       modifierFlags:0
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:0
                                               data1:0
                                               data2:0]
                 atStart:YES];
    }

    // Print progress dot every 2 seconds
    if (pollCount % 20 == 0) {
        fprintf(stderr, "  Waiting for scanner... (%ds)\n", pollCount / 10);
    }
}

- (BOOL)saveOutput {
    if (!gScannedImages || [gScannedImages count] == 0) return NO;

    NSString *outPath = self.outputPath;
    if (!outPath) outPath = generateOutputPath();

    if (gSettings.format == FORMAT_PDF) {
        return savePDF(gScannedImages, outPath);
    }

    // For non-PDF formats, copy/convert individual files
    int idx = 1;
    for (NSString *imgPath in gScannedImages) {
        NSString *destPath;
        if ([gScannedImages count] == 1) {
            destPath = outPath;
        } else {
            NSString *base = [outPath stringByDeletingPathExtension];
            NSString *ext = [outPath pathExtension];
            destPath = [NSString stringWithFormat:@"%@_%03d.%@", base, idx, ext];
        }

        // Convert TIFF to target format if needed
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:imgPath];
        if (!image) {
            fprintf(stderr, "Warning: Could not load %s\n", [imgPath UTF8String]);
            continue;
        }

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithData:[image TIFFRepresentation]];

        NSData *data = nil;
        switch (gSettings.format) {
            case FORMAT_TIFF:
                data = [rep TIFFRepresentation];
                break;
            case FORMAT_JPEG:
                data = [rep representationUsingType:NSBitmapImageFileTypeJPEG
                    properties:@{NSImageCompressionFactor: @0.9}];
                break;
            case FORMAT_PNG:
                data = [rep representationUsingType:NSBitmapImageFileTypePNG
                    properties:@{}];
                break;
            default:
                data = [rep TIFFRepresentation];
                break;
        }

        if (data) {
            [data writeToFile:destPath atomically:YES];
            fprintf(stderr, "Saved: %s\n", [destPath UTF8String]);
        }
        idx++;
    }

    return YES;
}

@end

// ============================================================================
// PDF Creation
// ============================================================================

static BOOL savePDF(NSArray *imagePaths, NSString *outputPath) {
    PDFDocument *pdfDoc = [[PDFDocument alloc] init];
    int pageIndex = 0;

    for (NSString *imgPath in imagePaths) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:imgPath];
        if (!image) {
            fprintf(stderr, "Warning: Could not load image %s\n", [imgPath UTF8String]);
            continue;
        }

        PDFPage *page = [[PDFPage alloc] initWithImage:image];
        if (page) {
            [pdfDoc insertPage:page atIndex:pageIndex];
            pageIndex++;
        }
    }

    if (pageIndex == 0) {
        fprintf(stderr, "Error: No pages to save\n");
        return NO;
    }

    BOOL ok = [pdfDoc writeToFile:outputPath];
    if (ok) {
        fprintf(stderr, "Saved: %s (%d page%s)\n",
                [outputPath UTF8String], pageIndex, pageIndex > 1 ? "s" : "");
    } else {
        fprintf(stderr, "Error: Failed to write PDF to %s\n", [outputPath UTF8String]);
    }

    return ok;
}

// ============================================================================
// Output Path Generation
// ============================================================================

static NSString *generateOutputPath(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];

    NSString *dir = [NSString stringWithUTF8String:gSettings.outputDir];
    NSString *ext = [NSString stringWithUTF8String:formatExtension(gSettings.format)];
    NSString *filename = [NSString stringWithFormat:@"scan_%@.%@", timestamp, ext];

    return [dir stringByAppendingPathComponent:filename];
}

// ============================================================================
// Perform a single scan (run NSApplication briefly)
// ============================================================================

static BOOL performScan(NSString *outputPath) {
    @autoreleasepool {
        ScanDelegate *delegate = [[ScanDelegate alloc] init];
        delegate.outputPath = outputPath;

        // Create or get the NSApplication
        NSApplication *app = [NSApplication sharedApplication];
        [app setDelegate:delegate];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // Run the application (blocks until scan completes)
        [app run];

        return delegate.scanSucceeded;
    }
}

// ============================================================================
// Terminal UI
// ============================================================================

static struct termios gOrigTermios;
static BOOL gTermRawMode = NO;

static void termRestoreMode(void) {
    if (gTermRawMode) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &gOrigTermios);
        gTermRawMode = NO;
    }
}

static void termRawMode(void) {
    if (gTermRawMode) return;
    tcgetattr(STDIN_FILENO, &gOrigTermios);
    atexit(termRestoreMode);

    struct termios raw = gOrigTermios;
    raw.c_lflag &= ~(ECHO | ICANON | ISIG);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    gTermRawMode = YES;
}

static void clearScreen(void) {
    printf("\033[H\033[2J");
    fflush(stdout);
}

static void showUI(void) {
    clearScreen();
    printf("\033[1m=== DS-720D Scanner ===\033[0m\n\n");
    printf("  [\033[1ms\033[0m] Source:  \033[32m%-10s\033[0m", scanSourceName(gSettings.scanSource));
    printf("  [\033[1mc\033[0m] Color:  \033[32m%s\033[0m\n", colorModeName(gSettings.colorMode));
    printf("  [\033[1md\033[0m] DPI:    \033[32m%-10d\033[0m", gSettings.dpi);
    printf("  [\033[1mf\033[0m] Format: \033[32m%s\033[0m\n", formatName(gSettings.format));
    printf("  [\033[1mo\033[0m] Output: \033[36m%s\033[0m\n", gSettings.outputDir);
    printf("\n");
    printf("  Press \033[1mENTER\033[0m to scan, \033[1mq\033[0m to quit\n");
    printf("\n");
    fflush(stdout);
}

static void cycleDPI(void) {
    static const int dpis[] = {150, 200, 300, 600};
    static const int ndpi = 4;
    for (int i = 0; i < ndpi; i++) {
        if (gSettings.dpi == dpis[i]) {
            gSettings.dpi = dpis[(i + 1) % ndpi];
            return;
        }
    }
    gSettings.dpi = 300; // Default
}

static void cycleColorMode(void) {
    switch (gSettings.colorMode) {
        case IMAGE_TYPE_COLOR: gSettings.colorMode = IMAGE_TYPE_GRAY; break;
        case IMAGE_TYPE_GRAY:  gSettings.colorMode = IMAGE_TYPE_BW; break;
        case IMAGE_TYPE_BW:    gSettings.colorMode = IMAGE_TYPE_COLOR; break;
        default:               gSettings.colorMode = IMAGE_TYPE_COLOR; break;
    }
}

static void cycleFormat(void) {
    gSettings.format = (gSettings.format + 1) % 4;
}

static void toggleScanSource(void) {
    gSettings.scanSource = (gSettings.scanSource == SCAN_SOURCE_SIMPLEX)
        ? SCAN_SOURCE_DUPLEX : SCAN_SOURCE_SIMPLEX;
}

static void runInteractive(void) {
    termRawMode();
    showUI();

    while (1) {
        char c;
        if (read(STDIN_FILENO, &c, 1) != 1) continue;

        switch (c) {
            case 'q':
            case 'Q':
            case 3:   // Ctrl+C
                termRestoreMode();
                clearScreen();
                printf("Bye.\n");
                return;

            case 's':
            case 'S':
                toggleScanSource();
                showUI();
                break;

            case 'c':
            case 'C':
                cycleColorMode();
                showUI();
                break;

            case 'd':
            case 'D':
                cycleDPI();
                showUI();
                break;

            case 'f':
            case 'F':
                cycleFormat();
                showUI();
                break;

            case 'o':
            case 'O':
                // Prompt for output directory
                termRestoreMode();
                printf("Output directory [%s]: ", gSettings.outputDir);
                fflush(stdout);
                {
                    char buf[1024];
                    if (fgets(buf, sizeof(buf), stdin)) {
                        // Trim newline
                        size_t len = strlen(buf);
                        while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r'))
                            buf[--len] = 0;
                        if (len > 0) {
                            // Expand tilde
                            NSString *path = [[NSString stringWithUTF8String:buf]
                                stringByExpandingTildeInPath];
                            strlcpy(gSettings.outputDir, [path UTF8String],
                                    sizeof(gSettings.outputDir));
                            // Create if needed
                            [[NSFileManager defaultManager]
                                createDirectoryAtPath:path
                                withIntermediateDirectories:YES
                                attributes:nil error:nil];
                        }
                    }
                }
                termRawMode();
                showUI();
                break;

            case '\r':
            case '\n':
                // Scan!
                termRestoreMode();
                printf("\n\033[1mScanning...\033[0m\n\n");
                fflush(stdout);
                {
                    NSString *outPath = generateOutputPath();
                    BOOL ok = performScan(outPath);
                    if (ok) {
                        printf("\n\033[32mScan complete!\033[0m\n");
                    } else {
                        printf("\n\033[31mScan failed.\033[0m\n");
                    }
                    printf("Press any key to continue...\n");
                    fflush(stdout);
                    termRawMode();
                    char dummy;
                    read(STDIN_FILENO, &dummy, 1);
                }
                showUI();
                break;

            default:
                break;
        }
    }
}

// ============================================================================
// Help
// ============================================================================

static void showHelp(void) {
    printf("dsscan - Terminal scanner for Brother DS-720D\n");
    printf("\n");
    printf("Usage:\n");
    printf("  dsscan                   Interactive mode\n");
    printf("  dsscan --scan            Scan with current settings\n");
    printf("  dsscan --help            Show this help\n");
    printf("\n");
    printf("Options (for --scan mode):\n");
    printf("  --color COLOR            Color mode: color, gray, bw (default: current)\n");
    printf("  --dpi DPI                Resolution: 150, 200, 300, 600 (default: current)\n");
    printf("  --duplex                 Duplex scanning\n");
    printf("  --simplex                Simplex scanning\n");
    printf("  --format FMT             Output format: pdf, tiff, jpeg, png (default: pdf)\n");
    printf("  --output PATH            Output file path\n");
    printf("\n");
    printf("Interactive mode keys:\n");
    printf("  s     Toggle simplex/duplex\n");
    printf("  c     Cycle color mode (Color > Gray > B&W)\n");
    printf("  d     Cycle DPI (150 > 200 > 300 > 600)\n");
    printf("  f     Cycle format (PDF > TIFF > JPEG > PNG)\n");
    printf("  o     Change output directory\n");
    printf("  ENTER Start scanning\n");
    printf("  q     Quit\n");
}

// ============================================================================
// Main
// ============================================================================

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        initSettings();

        // Parse arguments
        BOOL doScan = NO;
        NSString *outputPath = nil;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                showHelp();
                return 0;
            }
            else if (strcmp(argv[i], "--scan") == 0) {
                doScan = YES;
            }
            else if (strcmp(argv[i], "--color") == 0 && i + 1 < argc) {
                i++;
                if (strcasecmp(argv[i], "color") == 0) gSettings.colorMode = IMAGE_TYPE_COLOR;
                else if (strcasecmp(argv[i], "gray") == 0 || strcasecmp(argv[i], "grey") == 0)
                    gSettings.colorMode = IMAGE_TYPE_GRAY;
                else if (strcasecmp(argv[i], "bw") == 0 || strcasecmp(argv[i], "b&w") == 0)
                    gSettings.colorMode = IMAGE_TYPE_BW;
            }
            else if (strcmp(argv[i], "--dpi") == 0 && i + 1 < argc) {
                i++;
                gSettings.dpi = atoi(argv[i]);
            }
            else if (strcmp(argv[i], "--duplex") == 0) {
                gSettings.scanSource = SCAN_SOURCE_DUPLEX;
            }
            else if (strcmp(argv[i], "--simplex") == 0) {
                gSettings.scanSource = SCAN_SOURCE_SIMPLEX;
            }
            else if (strcmp(argv[i], "--format") == 0 && i + 1 < argc) {
                i++;
                if (strcasecmp(argv[i], "pdf") == 0) gSettings.format = FORMAT_PDF;
                else if (strcasecmp(argv[i], "tiff") == 0) gSettings.format = FORMAT_TIFF;
                else if (strcasecmp(argv[i], "jpeg") == 0 || strcasecmp(argv[i], "jpg") == 0)
                    gSettings.format = FORMAT_JPEG;
                else if (strcasecmp(argv[i], "png") == 0) gSettings.format = FORMAT_PNG;
            }
            else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
                i++;
                outputPath = [[NSString stringWithUTF8String:argv[i]]
                    stringByExpandingTildeInPath];
            }
            else {
                fprintf(stderr, "Unknown option: %s\n", argv[i]);
                fprintf(stderr, "Use --help for usage info\n");
                return 1;
            }
        }

        if (doScan) {
            // If --output is a directory, generate filename within it
            if (outputPath) {
                BOOL isDir = NO;
                if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath
                                                         isDirectory:&isDir] && isDir) {
                    strlcpy(gSettings.outputDir, [outputPath UTF8String],
                            sizeof(gSettings.outputDir));
                    outputPath = generateOutputPath();
                }
            }
            if (!outputPath) outputPath = generateOutputPath();

            fprintf(stderr, "%s | %s | %d DPI | %s -> %s\n",
                    scanSourceName(gSettings.scanSource),
                    colorModeName(gSettings.colorMode),
                    gSettings.dpi,
                    formatName(gSettings.format),
                    [outputPath UTF8String]);

            performScan(outputPath);
            // performScan calls _exit() on success, so we only get here on failure
            return 1;
        }

        // Default: interactive mode
        if (!isatty(STDIN_FILENO)) {
            fprintf(stderr, "Error: Interactive mode requires a terminal\n");
            return 1;
        }

        runInteractive();
        return 0;
    }
}
