# DSmobileCapture & Brother DS-720D Scanner Research

## Scanner Hardware

- **Model**: Brother DS-720D (portable duplex document scanner)
- **Manufacturer**: Avision (OEM), branded as Brother
- **USB**: Vendor ID 0x04f9 (Brother), Product ID 0x60e2
- **Serial**: U63567G5U112784
- **Connection**: USB 2.0 (High Speed), appears as USB composite device
- **Protocol**: SCSI commands over USB Mass Storage class
- **Kernel Extension**: `com_BrKernel` handles low-level USB/SCSI communication
- **IORegistry path**: IOUSBHostDevice → IOUSBMassStorageInterfaceNub → IOSCSILogicalUnitNub → com_BrKernel

## DSmobileCapture Application

- **Bundle ID**: `Avision.DSmobileCapture`
- **Version**: 3.0.0.0
- **Binary**: Mach-O 64-bit x86_64 (no ARM/Apple Silicon native)
- **Built with**: Xcode 8.2.1, macOS 10.12 SDK
- **Copyright**: 2019 Brother
- **Framework**: Cocoa + TWAIN.framework + Quartz.framework
- **Main class**: Uses NSApplication with MainMenu.nib

### How DSmobileCapture Works

The app is a TWAIN client. It follows this communication path:

```
DSmobileCapture.app
  → TWAIN.framework (DSM_Entry - Data Source Manager)
    → DS-720D.ds (TWAIN Data Source at /Library/Image Capture/TWAIN Data Sources/)
      → com_BrKernel (kernel extension)
        → USB/SCSI → Scanner hardware
```

#### TWAIN Flow:
1. Opens the TWAIN DSM via `DSM_Entry(MSG_OPENDSM)`
2. Enumerates data sources via `MSG_GETFIRST`/`MSG_GETNEXT`
3. Selects "Brother DS-720D TWAIN" via `MSG_OPENDS`
4. Reads settings from `avscan.plist`
5. Sets TWAIN capabilities (color, DPI, duplex, etc.)
6. Enables the data source with `MSG_ENABLEDS` (ShowUI=false, uses own UI)
7. Receives image data via `DAT_IMAGENATIVEXFER`
8. Saves to disk in selected format (BMP/JPEG/TIFF/PNG/PDF)
9. Closes DS via `MSG_CLOSEDS` and DSM via `MSG_CLOSEDSM`

### Key Objective-C Classes (from binary strings):
- `TWAINController` - Main TWAIN interaction
- `TWAINHandler` (C++ class `12TWAINHandler`)
- `DS720DScan` - Scanner-specific operations
- `ImageProcess` - Post-scan image processing
- Methods: `fileScan`, `mScanSetup`, `mSaveScanFlow`, `menuFileScan:`, `imageTypeChanged`

### File Format Support:
The app can save as:
- BMP (`saveAsBMPWithName:`)
- JPEG (`saveAsJpegWithName:`, `saveAsJpeg2WithName:`)
- TIFF (`appendTIFFImage:`)
- PNG
- PDF (`CreatePDF:`, `CreateMPDF:`, `appendPdf:`)
- Multi-page TIFF (`mergeTiffImage:`, `mergeTiffImageEx:`)
- Multi-page PDF (`appendPdfAtURL:toContext:`)

## TWAIN Data Source: DS-720D.ds

**Location**: `/Library/Image Capture/TWAIN Data Sources/DS-720D.ds/`
**Bundle ID**: `com.brother.ds720dds`
**Version**: 1.5.5
**Product Name**: "Brother DS-720D TWAIN"

### Architecture:
```
DS-720D.ds/
  Versions/A/
    DS-720D          (main TWAIN DS binary, 1.3MB)
    avscan.plist     (current scan configuration)
    Resources/
      DS-720D.dylib  (scanner communication library, 1.1MB)
      AVCocoa.dylib  (Avision Cocoa helpers, 160KB)
      CMatch.dylib   (color matching, 384KB)
      SmartImage.dylib (image processing, 6.5MB)
      DeviceList.plist (supported USB device IDs)
      DSDebug.plist   (TWAIN protocol debug definitions)
      TwainDSDialog.nib (settings dialog UI)
      icc/            (ICC color profiles for various scanner models)
```

### Supported Devices (from DeviceList.plist):
USB Vendor 0x04F9 (Brother):
- 0x60E0: DS-620
- 0x60E1: DS-620
- 0x60E2: **DS-720D** (our scanner)
- 0x60E4: DS-820W
- 0x60E5: MDS-820W
- 0x60E6: DS-920DW
- 0x60E7: DS-920DW

Also supports Avision scanners (vendor 0x0638) and others.

### Configuration (avscan.plist)

The TWAIN data source stores its current configuration in `avscan.plist`. This is read by the DS when a scan is initiated. Key fields:

| Field | Current Value | Meaning |
|-------|--------------|---------|
| `ImageType` | 12 | Color mode (enum - see below) |
| `ScanSource` | 1 | 0=Simplex(?), 1=Duplex(?) |
| `BWRes` | 200 | B&W scanning DPI |
| `GrayRes` | 200 | Grayscale scanning DPI |
| `ColorRes` | 300 | Color scanning DPI |
| `PaperSize` | 0 | Paper size (0=auto/letter?) |
| `Width` | 2550 | Scan width in 1/300" (= 8.5 inches) |
| `Length` | 4200 | Scan length in 1/300" (= 14 inches) |
| `LongWidth` | 2550 | Max width |
| `LongLength` | 9600 | Max length (32 inches) |
| `ColorMatch` | 2 | Color matching mode |
| `BlankPageRemoval` | 0 | Auto-remove blank pages |
| `Rotation` | 0 | Auto-rotation |
| `TransportTimeout` | 30 | Seconds to wait for paper |
| `EnergySaver` | 15 | Minutes to energy save |
| `PowerOffTime` | 240 | Minutes to auto power off |
| `ImageCount` | -1 | Number of images (-1 = all) |

#### Front/Rear Settings (for duplex):
Settings prefixed with `F` are for the front side, `R` for the rear side:
- `FB*` = Front B&W settings (Brightness, Threshold, ColorDropOut, etc.)
- `FG*` = Front Gray settings
- `FC*` = Front Color settings
- `RB*` = Rear B&W settings
- `RG*` = Rear Gray settings
- `RC*` = Rear Color settings

### Internal Data Structures (from binary strings):

#### Scan Parameter Structure:
```c
struct ScanParameter {
    uint16_t Left, Top, Width, Length;
    uint16_t PixelNum, LineNum;
    uint8_t  ScanMode;      // scanning mode
    uint8_t  ScanMethod;    // scanning method
    uint8_t  BitsPerPixel;
    uint8_t  ScanSpeed;
    int8_t   Contrast, Brightness;
    uint8_t  HTPatternNo, Highlight, Shadow;
    uint8_t  ColorFilter, Invert, ReadStatus;
    uint16_t XRes, YRes;
    // ... more fields
};
```

#### Image Type Structure:
```c
struct ImageTypeSettings {
    uint16_t wImageType;
    uint8_t  bFBinaryProcess, bRBinaryProcess;  // Front/Rear BW processing
    uint8_t  bFDTSensitivity, bRDTSensitivity;
    uint8_t  bFBThreshold, bRBThreshold;
    // ... brightness, contrast, invert for each mode (F/R, B/G/C)
    uint8_t  bFGrayQuality, bRGrayQuality;
    uint16_t wBWRes, wGrayRes, wColorRes;       // DPI per mode
    uint8_t  bColorMatch, bPaperSize, bScanSource;
    // ... color dropout, advanced processing, filter thresholds
    uint8_t  bRotation, bBlankPageRemoval, bBlankPageThreshold;
    int32_t  iImageCount;
    uint16_t wEnergySaver, wPowerOffTime;
    uint8_t  bTransportTimeout;
    // ... etc
};
```

## TWAIN Framework on macOS

- **Location**: `/System/Library/Frameworks/TWAIN.framework`
- **Status**: Still present on macOS 15.6 (Sequoia), though deprecated since 10.9
- **Export**: Single function `DSM_Entry`
- **Header**: `TWAIN.h` in SDK

### Key TWAIN Constants:

#### Data Groups:
- `DG_CONTROL` (1) - Control operations
- `DG_IMAGE` (2) - Image operations

#### Data Argument Types:
- `DAT_IDENTITY` (0x0003) - Source identity
- `DAT_CAPABILITY` (0x0001) - Capability negotiation
- `DAT_USERINTERFACE` (0x0009) - UI control
- `DAT_IMAGENATIVEXFER` (0x0104) - Native image transfer
- `DAT_IMAGEFILEXFER` (0x0105) - File-based image transfer
- `DAT_IMAGEMEMXFER` (0x0103) - Memory-based image transfer
- `DAT_PENDINGXFERS` (0x0005) - Pending transfers

#### Messages:
- `MSG_OPENDSM` (0x0301) - Open Data Source Manager
- `MSG_CLOSEDSM` (0x0302) - Close DSM
- `MSG_OPENDS` (0x0401) - Open a data source
- `MSG_CLOSEDS` (0x0402) - Close a data source
- `MSG_GETFIRST` (0x0004) - Get first data source
- `MSG_GETNEXT` (0x0005) - Get next data source
- `MSG_ENABLEDS` (0x0502) - Enable data source
- `MSG_DISABLEDS` (0x0501) - Disable data source
- `MSG_GET` (0x0001) - Get capability value
- `MSG_SET` (0x0006) - Set capability value
- `MSG_XFERREADY` (0x0101) - Data ready for transfer
- `MSG_ENDXFER` (0x0701) - End transfer

#### Capabilities:
- `CAP_XFERCOUNT` (0x0001) - Number of images to transfer
- `ICAP_PIXELTYPE` (0x0101) - BW/Gray/RGB
- `ICAP_XRESOLUTION` (0x1118) - Horizontal DPI
- `ICAP_YRESOLUTION` (0x1119) - Vertical DPI
- `CAP_FEEDERENABLED` (0x1002) - Use document feeder
- `CAP_FEEDERLOADED` (0x1003) - Paper in feeder?
- `CAP_DUPLEX` (0x1012) - Duplex capable?
- `CAP_DUPLEXENABLED` (0x1013) - Enable duplex
- `CAP_UICONTROLLABLE` (0x100e) - Can operate without UI
- `ICAP_IMAGEFILEFORMAT` (0x110c) - File format for file transfer
- `ICAP_COMPRESSION` (0x0100) - Compression type
- `ICAP_SUPPORTEDSIZES` (0x1122) - Paper sizes

#### Pixel Types:
- `TWPT_BW` (0) - Black and White
- `TWPT_GRAY` (1) - Grayscale
- `TWPT_RGB` (2) - Color

#### File Formats:
- `TWFF_TIFF` (0) - TIFF
- `TWFF_BMP` (2) - BMP
- `TWFF_JFIF` (4) - JPEG
- `TWFF_TIFFMULTI` (6) - Multi-page TIFF
- `TWFF_PNG` (7) - PNG

#### Return Codes:
- `TWRC_SUCCESS` (0)
- `TWRC_FAILURE` (1)
- `TWRC_CHECKSTATUS` (2)
- `TWRC_CANCEL` (3)
- `TWRC_XFERDONE` (6) - Transfer complete
- `TWRC_ENDOFLIST` (7)

### TW_USERINTERFACE Structure:
```c
typedef struct TW_USERINTERFACE {
    TW_BOOL   ShowUI;   // FALSE for headless operation
    TW_BOOL   ModalUI;  // Mac only
    TW_HANDLE hParent;  // Window handle (NULL for CLI?)
} TW_USERINTERFACE;
```

## macOS ICA (Image Capture Architecture) - NOT Compatible

The Brother ICA plugin at `/Library/Image Capture/Devices/Brother Scanner.app` (v4.0.3) does NOT list the DS-720D in its supported devices. It supports newer models:
- DS-640, DS-740D, DS-940DW
- DS-1000W through DS-3600W series
- Various ADS models

The `DeviceMatchingInfo.plist` and `DeviceInfo.plist` in the Brother Scanner.app have no entry for the DS-720D or USB product ID 0x60E2. This means:
- **ImageCaptureCore framework will not discover this scanner**
- Tools like `scanline` (which uses ImageCaptureCore) won't work
- macOS Image Capture.app may not support it either

## SANE (Scanner Access Now Easy)

- `sane-backends` available via Homebrew (v1.4.0)
- Not currently installed on system
- May support DS-720D through `avision` or `brother_ds` backend
- The scanner uses SCSI over USB, which is a common SANE transport
- Provides `scanimage` CLI tool
- Worth testing as simplest path to CLI scanning

## DSmobileCapture App Config

The app stores per-scanner settings in:
`DSmobileCapture.app/Contents/MacOS/AvCaptureTool_lng.plist`

Current settings:
- `ScannerName`: "Brother DS-720D TWAIN"
- `FileFormat`: 3 (PDF)
- `SavePath`: "/Users/mbafford/Documents/Image"
- `ShowInFinder`: 0
- `Language`: 0 (English)

## Summary of Approaches for CLI Tool

| Approach | Pros | Cons | Feasibility |
|----------|------|------|-------------|
| SANE + scanimage | Simple CLI, well-tested | External dep, may not support all features | Try first |
| Swift TWAIN CLI | Native, full control | Complex API, deprecated framework | Fallback |
| Plist + DSmobileCapture | Uses working code | Still needs GUI app | Not ideal |
| ImageCaptureCore | Modern Apple API | DS-720D not supported | Won't work |
