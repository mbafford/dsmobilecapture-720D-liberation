# dsscan - CLI Scanner for Brother DS-720D

A terminal-based scanning tool for the Brother DS-720D portable duplex document scanner on macOS. Replaces the clunky DSmobileCapture GUI app with a fast command-line interface.

Why?  Because the current macOS application is clunky and hard to use and I find it generally unpleasant.  It often crashes between scans, it requires multiple clicks to switch from simplex/duplex or color/grayscale. 

The drivers are all in x86_64, so this requires Rosetta 2 on Apple Silicon Macs.

## Features

- Single-shot or interactive scanning modes
- Simplex/duplex scanning
- Color, grayscale, and B&W modes
- Adjustable DPI (150, 200, 300, 600)
- Output to PDF (multi-page), TIFF, JPEG, or PNG
- Multi-sheet scanning with automatic page collation

## Prerequisites

### macOS Version

Tested on macOS 15 (Sequoia). Requires Rosetta 2 on Apple Silicon Macs (the DS-720D TWAIN driver is x86_64 only).

### Brother DS-720D Driver

The scanner requires Brother's TWAIN driver. Install it from Brother's support site:

1. Download the **DS-720D driver** from [Brother support](https://support.brother.com/g/b/downloadtop.aspx?c=us&lang=en&prod=ds720d_us)
   - You need the "Scanner Driver" package (not just the DSmobileCapture app)
2. Run the installer
3. Verify the TWAIN data source is installed:
   ```
   ls /Library/Image\ Capture/TWAIN\ Data\ Sources/DS-720D.ds/
   ```
4. The installer also installs a kernel extension (`com_BrKernel`) for USB/SCSI communication with the scanner

### Xcode Command Line Tools

```
xcode-select --install
```

## Building

```
make
```

This compiles `dsscan.m` as an x86_64 binary (required to load the x86_64-only TWAIN driver via Rosetta 2).

Optional install to PATH:

```
sudo make install
```

## Usage

### Interactive Mode

```
./dsscan
```

```
=== DS-720D Scanner ===

  [s] Source:  Duplex        [c] Color:  Color
  [d] DPI:    300            [f] Format: PDF
  [o] Output: ~/Documents/Scans

  Press ENTER to scan, q to quit
```

Single-keystroke controls:
- `s` - Toggle simplex/duplex
- `c` - Cycle color mode (Color > Gray > B&W)
- `d` - Cycle DPI (150 > 200 > 300 > 600)
- `f` - Cycle format (PDF > TIFF > JPEG > PNG)
- `o` - Change output directory
- `Enter` - Scan
- `q` - Quit

### Command-Line Mode

```
# Duplex grayscale scan at 200 DPI, save PDF to current directory
./dsscan --scan --duplex --color gray --dpi 200 --format pdf --output .

# Simplex color scan at 300 DPI
./dsscan --scan --simplex --color color --dpi 300 --output ~/Documents/Scans/

# B&W scan to TIFF
./dsscan --scan --color bw --dpi 200 --format tiff --output scan.tiff
```

### Options

| Option | Values | Default |
|--------|--------|---------|
| `--color` | `color`, `gray`, `bw` | From scanner config |
| `--dpi` | `150`, `200`, `300`, `600` | From scanner config |
| `--duplex` / `--simplex` | | From scanner config |
| `--format` | `pdf`, `tiff`, `jpeg`, `png` | `pdf` |
| `--output` | File path or directory | `~/Documents/Scans/scan_<timestamp>.pdf` |

## How It Works

`dsscan` communicates with the scanner through the same TWAIN protocol as DSmobileCapture:

```
dsscan (this tool)
  -> TWAIN.framework (macOS Data Source Manager)
    -> DS-720D.ds (Brother TWAIN Data Source)
      -> com_BrKernel (kernel extension)
        -> USB/SCSI -> Scanner hardware
```

Scanner settings (color mode, DPI, duplex, etc.) are written to the TWAIN data source's config file (`avscan.plist`) before each scan, then TWAIN capabilities are set programmatically. Images are transferred via memory-based transfer and assembled into the output format.

### Driver Bug Workaround

The DS-720D TWAIN driver has a bug where it tries to close an NSWindow from a background thread after scanning, which crashes the process. `dsscan` works around this by method-swizzling the offending method to dispatch to the main thread at runtime.

## Implementation

This project was built from scratch using [Claude Code](https://claude.ai/claude-code) (Claude Opus 4.6) in a single session. No source code from the original DSmobileCapture app was available, used, or decompiled.

The implementation was based on:

- **The TWAIN specification** - The public `TWAIN.h` header in the macOS SDK documents the `DSM_Entry` function, all protocol constants, and data structures. TWAIN is a standardized scanner API.
- **Configuration file inspection** - The DS-720D.ds driver bundle contains `avscan.plist` (scanner settings) and `DeviceList.plist` (supported USB device IDs), both plain-text XML plists.
- **Runtime crash analysis** - The driver bug workaround (method swizzle of `DialogBoxController.closeTransportWindow`) was discovered from reading crash stack traces during testing, then fixed using the standard Objective-C runtime API.
- **Binary string inspection** - Class and method names found via `strings` on the DSmobileCapture binary were used to understand the communication flow and config format, documented in `DSMobileCapture-720D-research.md`.

## Troubleshooting

**"No TWAIN data sources found"** - The DS-720D.ds driver is not installed. Install the Brother scanner driver package.

**"Scanner appears to be offline"** - Check the USB connection. Try unplugging and replugging the scanner.

**"Scanner may be in use by another application"** - Close DSmobileCapture or any other scanning app.

**Scanner not detected at all** - On Apple Silicon Macs, make sure Rosetta 2 is installed (`softwareupdate --install-rosetta`).

## License

MIT
