# iPhone Duo macOS Animation

The **iPhone Duo fold animation** for MacBooks driven by the physical lid angle sensor.

> *"When the Duo opens or closes, the picture on its screen stays where it is in space while the hardware sweeps through it: the image frosts over and slips into black without ever changing its size."*

This project brings the 1:1 folding animation from [soloiaros/iphone-solo](https://github.com/soloiaros/iphone-solo) directly to macOS, driven by the real-time physical lid angle sensor documented in [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor).

Rather than rendering inside a separate window, **the entire macOS display follows the animation in 3D space** as you open and close your MacBook lid.

---

## Features

- 📐 **Physical Lid Angle Sensing**: Real-time 60 Hz polling of Apple's internal lid angle sensor (`IOHIDDevice` Vendor `0x05AC`, Product `0x8104`, UsagePage `0x0020`, Usage `0x008A`).
- 🌊 **Exact 1:1 Shaders**: Native Metal Shading Language implementation of the original WebGL 2 pipeline:
  - 3D perspective projection with hinge bend
  - 5-tap separable Gaussian blur mip chain
  - Glass tint and specular rim reflections
  - Dark void horizon falloff
- 🖥️ **Full-Screen Seamless Overlay**: Spans the entire screen at `.screenSaver` level. Completely click-through and invisible when open, freezing and folding into 3D space on tilt.
- 🎛️ **Liquid Glass Desktop App**: Built exclusively with Swift native `.glass` APIs (`.glassEffect()`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`):
  - **Tilt Trigger Customization**: Customize exactly when the animation starts (e.g. 110°) and when full fold is reached (e.g. 15°).
  - **Follow Responsiveness**: Tune the exponential smoothing physics.
  - **Hinge Style**: Clamshell (MacBook bottom hinge), iPhone Solo Left, or iPhone Solo Right.
  - **Image Source**: Live Screen Capture (`ScreenCaptureKit`), Desktop Wallpaper, Bundled Solo Artwork, or Custom Photo.
  - **Test Preview Slider**: Scrub and preview the folding animation interactively without moving your MacBook lid.
- 🍸 **Menu Bar Extra**: Quick angle readout (e.g. `126°`), status monitoring, and settings shortcuts.
- 🚀 **Automated Build & Install (`build.sh`)**: Increments the version number and build number automatically on each run and installs the `.app` directly to `/Applications`.

---

## Requirements

- macOS 14.0 or later (Apple Silicon or Intel MacBook with lid angle sensor)
- Xcode Command Line Tools (`swiftc`, `xcrun metal`)

---

## Building & Installing

Run the automated build script:

```bash
./build.sh
```

Every time `./build.sh` is executed:
1. It automatically increments the patch version (e.g. `1.0.0` → `1.0.1`) and build number (e.g. `1` → `2`) in `Info.plist`.
2. Compiles the Metal shaders into `default.metallib`.
3. Compiles the Swift application.
4. Codesigns the app bundle ad-hoc.
5. Installs the new version directly to `/Applications/iPhoneDuo.app`.

---

## Launching

Open the installed application from `/Applications` or run:

```bash
open /Applications/iPhoneDuo.app
```

The menu bar icon will display your current lid angle in degrees. The Liquid Glass control panel allows you to customize the tilt thresholds and test the animation live!

---

## Credits & Acknowledgements

- **Animation & Shader Math**: [soloiaros/iphone-solo](https://github.com/soloiaros/iphone-solo) by [@soloiaros](https://github.com/soloiaros).
- **Lid Angle Sensor Reverse-Engineering**: [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) by [@samhenrigold](https://github.com/samhenrigold).
