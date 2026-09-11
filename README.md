# macTilt

The **macTilt** 3D clamshell fold animation for MacBooks driven by the physical lid angle sensor.

> *"When the lid closes, the picture on its screen stays where it is in space while the hardware sweeps through it: the image frosts over and slips into black without ever changing its size."*

Rather than rendering inside a separate window, **the entire macOS display follows the animation in 3D space as you close your MacBook lid**.

## NOTE
- **锁屏开盖动画（本地增强版）**：通过 SkyLight 私有显示空间呈现壁纸展开动画。唤醒时补充 0.8 秒展开过渡；锁定期间以 60 Hz 持续读取开合角度，反复合盖、开盖均可触发，没有动画截止时间。系统真正睡眠时进程暂停，唤醒后恢复。接口可能随系统更新变化；不适用于重启后的 FileVault 预启动解锁界面。
- **Normal MacBook Use**: When you are actively using your MacBook (lid is open), the app does **nothing** (overlay is completely hidden, zero CPU/GPU overhead, full click-through).
- **Closing MacBook**: As you tilt the screen closed, the display freezes the screen and seamlessly folds **from up to down** toward the bottom keyboard hinge into the dark void.
---

## Features

- 📐 **Physical Lid Angle Sensing**: Real-time 60 Hz polling of Apple's internal lid angle sensor (`IOHIDDevice` Vendor `0x05AC`, Product `0x8104`, UsagePage `0x0020`, Usage `0x008A`).
- 🌊 **Exact 1:1 Shaders**: Native Metal Shading Language implementation:
  - 3D perspective projection with up-to-down clamshell hinge bend
  - 5-tap separable Gaussian blur mip chain
  - Glass tint and specular rim reflections
  - Dark void horizon falloff
- 🖥️ **Full-Screen Seamless Overlay**: Spans the entire screen at `.screenSaver` level. Completely click-through and invisible when open, freezing and folding into 3D space on tilt.
- 🎛️ **Liquid Glass Desktop App**: Built with crisp native styling and Swift native `.glass` APIs (`.glassEffect()`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`):
  - **Menu Bar Display Toggle**: Option to hide or show the numerical lid sensor angle from the menu bar.
  - **Screen Recording Permission Check**: Real-time permission status check and one-click authorization request.
  - **Tilt Trigger Customization**: Customize exactly when the animation starts (e.g. 80°) and when full fold is reached (e.g. 3°).
  - **Follow Responsiveness**: Tune the exponential smoothing physics.
  - **Image Source**: Live Screen Capture (`ScreenCaptureKit`), Desktop Wallpaper, Bundled Artwork, or Custom Photo.
  - **Test Preview Slider**: Scrub and preview the up-to-down closing fold interactively without moving your MacBook lid.
- 🍸 **Menu Bar Extra**: Quick angle readout (e.g. `126°`), status monitoring, and settings shortcuts.
- 🚀 **Automated Build & Install (`build.sh`)**: Builds without modifying source version metadata and installs the `.app` directly to `/Applications`.

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

The script compiles both architectures, signs the bundles, creates a DMG, and installs to `/Applications`.
Build outputs stay in the ignored `build/` directory. To build without installing:

```bash
./build.sh --no-install
```

Ad-hoc signing is the default and does not require an Apple Developer account.
To use your own certificate, pass its SHA-1 fingerprint through `SIGNING_IDENTITY`;
do not commit certificate files or local signing configuration.

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

---

## Credits & Acknowledgements

- **Lid Angle Sensor**: Inspired by hardware reverse-engineering documented in [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) by [@samhenrigold](https://github.com/samhenrigold).


## 中文本地增强版：后台运行

关闭控制面板后，应用仍在菜单栏运行。使用 `--background` 参数启动时不弹出设置窗口。
如需登录自启动，可在当前用户下配置 LaunchAgent： `~/Library/LaunchAgents/com.lqsky7.mactilt.background.plist`，
登录后运行 `/Applications/macTilt.app/Contents/MacOS/macTilt --background`。
启用该启动项后，下次登录会在后台启动。菜单栏“退出 macTilt”仍可正常退出。

锁屏显示空间的实现参考 [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow)，
MIT 许可见 `Resources/ThirdParty/SkyLightWindow-LICENSE.txt`。
