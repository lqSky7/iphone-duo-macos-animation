# macTilt

The **macTilt** 3D clamshell fold animation for MacBooks driven by the physical lid angle sensor.

> *"When the lid closes, the picture on its screen stays where it is in space while the hardware sweeps through it: the image frosts over and slips into black without ever changing its size."*

Rather than rendering inside a separate window, **the entire macOS display follows the animation in 3D space as you close your MacBook lid**.

## NOTE
- **Lock Screen Animation**: Unfolds the wallpaper on the lock screen through a private SkyLight display space. It requires System Integrity Protection (SIP) to be disabled; while SIP is enabled, the option is greyed out in the control panel. Waking adds a 0.8-second unfold transition. While the Mac is locked, the lid angle is read at 60 Hz, so closing and opening the lid repeatedly keeps animating with no time limit. The process pauses during real system sleep and resumes on wake. The private interface may change with macOS updates, and it does not apply to the FileVault pre-boot unlock screen after a restart.
- **Normal MacBook Use**: When you are actively using your MacBook (lid is open), the app does **nothing** (overlay is completely hidden, zero CPU/GPU overhead, full click-through).
- **Closing MacBook**: As you tilt the screen closed, the picture stays frozen at the start angle while the display closes through it; the top frosts over and slips into the dark void first.
---

## Features

- 📐 **Physical Lid Angle Sensing**: Real-time 60 Hz polling of Apple's internal lid angle sensor (`IOHIDDevice` Vendor `0x05AC`, Product `0x8104`, UsagePage `0x0020`, Usage `0x008A`).
- 🌊 **Fold Shader**: Native Metal Shading Language implementation:
  - The picture stays frozen at the start angle while the display closes through it (fixed front-view projection, as on iPhone Duo)
  - Frost and darkening grow with the depth between the glass and the picture, so the top of the display goes dark first
  - Soft, rounded picture edges; hidden areas show a dim glow of scattered light instead of flat black
  - Frost blur averaged in linear light with a vibrancy boost, on smoked glass that dims as the lid closes
  - Optional glass reflection sheen
- 🖥️ **Full-Screen Seamless Overlay**: Spans the entire screen at `.screenSaver` level. Completely click-through and invisible when open, freezing and folding into 3D space on tilt.
- 🎛️ **Liquid Glass Desktop App**: Built with crisp native styling and Swift native `.glass` APIs (`.glassEffect()`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`):
  - **Menu Bar Display Toggle**: Option to hide or show the numerical lid sensor angle from the menu bar.
  - **Screen Recording Permission Check**: Real-time permission status check and one-click authorization request.
  - **Tilt Trigger Customization**: Choose the start angle, where the picture stays while the lid closes (e.g. 115°), and the end angle, where the display is fully dark (e.g. 3°).
  - **Follow Responsiveness**: Tune the exponential smoothing physics.
  - **Image Source**: Live Screen Capture (`ScreenCaptureKit`), Desktop Wallpaper, Bundled Artwork, or Custom Photo.
  - **Test Preview Slider**: Scrub through the fold interactively without moving your MacBook lid.
  - **Language**: Switch the interface between English and Simplified Chinese, or follow the system language.
- 🍸 **Menu Bar Extra**: Quick angle readout (e.g. `126°`), status monitoring, and settings shortcuts.
- 🚀 **Automated Build & Install (`build.sh`)**: Builds without modifying source version metadata and installs the `.app` directly to `/Applications`.

---

## Requirements

- macOS 14.0 or later (Apple Silicon or Intel MacBook with lid angle sensor)
- Xcode Command Line Tools (`swiftc`, `xcrun metal`)
- The lock screen animation additionally requires SIP to be disabled

---

## Building & Installing

Run the automated build script:

```bash
./build.sh
```

The script compiles both architectures, signs the bundles, creates a DMG, and installs to `/Applications`.
Build outputs stay in the ignored `build/` directory. To build without installing:

```bash
./build.sh --no-install
```

Ad-hoc signing is the default and does not require an Apple Developer account.
To use your own certificate, pass its SHA-1 fingerprint through `SIGNING_IDENTITY`;
do not commit certificate files or local signing configuration.

macOS ties the Screen Recording permission to the code signature. An ad-hoc build
gets a new signature every time, so grant the permission again after rebuilding;
a certificate keeps the signature stable across builds. A personal Apple Development
certificate also records its name, including your email address, in the signature,
so keep such builds local and share ad-hoc builds instead.

Optional `APP_VERSION` and `BUILD_NUMBER` environment variables override version
metadata only in the generated app bundle. Building never increments or modifies
the tracked `Info.plist`.


---

## Launching

Open the installed application from `/Applications` or run:

```bash
open /Applications/macTilt.app
```

The menu bar icon will display your current lid status. The Liquid Glass control panel allows you to customize the tilt thresholds and test the animation live!

### Running in the Background

macTilt keeps running in the menu bar after the control panel is closed. Launch it with `--background` to skip opening the settings window.
To start it at login, add a LaunchAgent for the current user, such as `~/Library/LaunchAgents/com.lqsky7.mactilt.background.plist`,
that runs `/Applications/macTilt.app/Contents/MacOS/macTilt --background`.
Once enabled, macTilt starts in the background at your next login. **Quit macTilt** in the menu bar still quits it normally.

---

## Credits & Acknowledgements

- **Lid Angle Sensor**: Inspired by hardware reverse-engineering documented in [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) by [@samhenrigold](https://github.com/samhenrigold).
- **Lock Screen Display Space**: Based on [Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) (MIT); see `Resources/ThirdParty/SkyLightWindow-LICENSE.txt`.
