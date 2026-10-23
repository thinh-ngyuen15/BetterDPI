# BetterDPI

Menu-bar app and CLI for display resolution, HiDPI, filters and system display controls on macOS.

| Feature | How |
|---|---|
| Resolution switching incl. hidden modes, HiDPI toggle | private `CGSGetNumberOfDisplayModes` / `CGSConfigureDisplayMode` |
| HiDPI virtual screen for non-Retina monitors | `CGVirtualDisplay` with HiDPI modes, monitor mirrored from it in place |
| Compositor filters (brightness, contrast, saturation, hue, blur, sepia, RGB gain, invert) | click-through window at `CGShieldingWindowLevel` hosting a private `CABackdropLayer` with `CAFilter`s; no capture, no latency |
| Video Filter Windows and Self-Stream | ScreenCaptureKit → Core Image chain (adjustments, 29 effects, 3D LUT) → Metal; numbered windows, autostart with restart, HDR option |
| 3D LUT library | `.cube` import (LUT_3D_SIZE 2–128), replace, rename, export → `CIColorCubeWithColorSpace` |
| Brightness upscaling | full-screen EDR Metal layer composited with a multiply blend |
| Variable refresh rate (ProMotion, Adaptive-Sync) | modes flagged by private `SLSIsDisplayModeVRR` / `SLSGetDisplayModeMinRefreshRate`; listed as *Variable* in the Refresh rate menu, plus a toggle when the current size has one |
| GPU dithering | `enableDither` on the display's `IOMobileFramebufferShim` |
| Night Shift, True Tone, Dark Mode | private `CBBlueLightClient`, `CBTrueToneClient`, `SLS*AppearanceThemeLegacy` |
| Safe mode and stored display settings | ⇧ Shift at launch skips every restore; per-display forget, auto-forget, full reset |

## Build

    ./build.sh            # -> build/BetterDPI.app (universal, ad-hoc signed)
    open build/BetterDPI.app

Open the menu-bar icon. Each display has an **Image & more** section (compositor filters,
brightness upscaling, GPU dithering, forget settings). The **System** section has Night Shift,
True Tone and Dark Mode. **Filters, Video Filter Windows & LUTs…** opens the filters window.

## App icon and Dock icon

The icon is generated from `logo.png` by `tools/make_icon.swift` into `Resources/AppIcon.icns`
(plus `Resources/AppIcon-1024.png` as a preview). `build.sh` regenerates it whenever `logo.png` is
newer, and copies it into the app. The generator crops the monitor, magnifier and "2x" badge out of
the screenshot and composes a full-bleed, opaque 1024 px square without an alpha channel. macOS 26+
shows anything else (transparent margins, a squircle cut-out, even an opaque image saved with an alpha
channel) inside a grey tile; a full-bleed square is masked to the system's own icon shape instead. If
`logo.png` changes, re-measure the crop rectangles at the top of the script.

BetterDPI is a menu-bar app. The **Dock icon** setting in the menu chooses when it also appears in the
Dock: *Never*, *While a window is open* (default; the Filters window) or *Always*.

## Permissions

* **Screen Recording** is needed for Video Filter Windows only. Grant it under System Settings >
  Privacy & Security > Screen Recording and relaunch. Because the build is ad-hoc signed, macOS
  may ask again after each rebuild.
* Everything else needs no permission and no administrator rights.

## CLI

    BetterDPI list
    BetterDPI modes <id> [--all]
    BetterDPI set <id> <index> | <W>x<H> [hidpi|lodpi] [@Hz] [vrr|fixed]
    BetterDPI hidpi <id> on|off
    BetterDPI vrr <id> [on|off]                 # variable refresh rate at the current size
    BetterDPI virtual <id>                      # until Ctrl-C
    BetterDPI dither <id> [on|off]
    BetterDPI nightshift [on|off|0-100]
    BetterDPI truetone [on|off]
    BetterDPI darkmode [on|off]
    BetterDPI filter <id> saturation=0,invert=on  # compositor filters until Ctrl-C
    BetterDPI upscale <id> [gain]               # until Ctrl-C
    BetterDPI videofilter <src> <target|self> [key=value,...]   # until Ctrl-C

The binary is `build/BetterDPI.app/Contents/MacOS/BetterDPI`; with no arguments it starts the
menu-bar app. The long-running commands do not save anything.

## Limits

* The compositor layer only runs Core Animation filters; effects and LUTs need a Video Filter
  Window (the window server ignores Core Image filters on a backdrop layer, verified on macOS 27).
* Brightness upscaling needs EDR headroom: built-in XDR panels, Pro Display XDR, or an HDR
  monitor in HDR mode.
* LUTs must use a 0…1 input domain; HDR (PQ) LUTs are not supported.
* Quit other display-management apps before using the HiDPI virtual screen: they also manage
  virtual displays and mirroring.
* Everything private can change in a future macOS release. CoreBrightness, SkyLight,
  CABackdropLayer/CAFilter and the framebuffer property are looked up at runtime, so their
  controls just disappear (or report unavailable) if they go away. CGS and CGVirtualDisplay are
  linked directly; if Apple removed those, the app would not launch.

## License

MIT. See [LICENSE](LICENSE).
