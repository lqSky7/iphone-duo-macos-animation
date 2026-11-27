# macTilt

The **macTilt** 3D clamshell fold animation for MacBooks, driven by the physical lid angle sensor.

> *"When the lid closes, the picture on its screen stays where it is in space while the hardware sweeps through it: the image frosts over and slips into black without ever changing its size."*

Rather than rendering inside a separate window, **the entire macOS display follows the animation in 3D space as you close your MacBook lid**.

## NOTE

- **Opening MacBook**: Works on lockscreen via private skyline APIs
- **Normal MacBook Use**: when you are actively using your MacBook (lid open), the app does **nothing** — the overlay is completely hidden, with zero CPU/GPU overhead and full click-through.
- **Closing MacBook**: as you tilt the screen closed, the display freezes the screen and seamlessly folds **from up to down** toward the bottom keyboard hinge into the dark void.
- **Clamshell desktop mode**: with an external display attached and the built-in panel asleep, the effect is suppressed — there is no visible hinge motion to animate.
- **Before permission is granted**: with the live-capture source selected, the effect stays entirely off until Screen Recording is allowed. Nothing is drawn over the desktop and the app is inert, so a lid that is already partly shut at launch cannot leave a frozen-looking image on screen.
- **No Input Monitoring**: macTilt reads a single feature report from Apple's lid angle sensor. It never listens for keyboard or pointer input, so it does not need Input Monitoring — and on a Mac without the sensor it never opens a HID device at all. To stop the probe entirely, run `defaults write com.lqsky7.mactilt mactilt_probeLidAngleSensor -bool NO` and relaunch; macTilt then runs on the clamshell switch only.

---

## Hardware Support

macTilt adapts to the lid hardware it finds:

- **Macs with Apple's continuous lid angle sensor** (Vendor `0x05AC`, Product `0x8104`, UsagePage `0x0020`, Usage `0x008A`): the fold is driven 1:1 by the live hinge angle, at up to 120 Hz.
- **Macs with only the binary clamshell switch** (for example the MacBook Pro 13" M1): there is no continuous angle to read, so macTilt plays a smooth time-based unfold whenever the lid opens, with an adjustable duration.

Which of the two a machine is gets decided from the IORegistry, before any HID access, so a Mac with no sensor never opens a HID device — and the probe itself only ever opens the sensor, never the accelerometer, gyroscope or ambient light sensor that share its product ID.

---

## Features
- just install and see duh

### Duo Mode

**Settings → Physics & Shaders → Duo Mode** (on by default). The picture looks like it is still standing upright at 90° while the lid closes: the lid becomes a window onto a screen that stays put, black creeps in from the sides, and the blur grows toward the top. Duo Mode has a fixed look, so Blur Intensity, Specular Reflection and Side Blackout are greyed out while it is on. Turn it off for the original macTilt fold, shaped by those settings.

The lid angle sensor only changes about 10 times a second, in 2–15° jumps. Duo Mode plays each new reading in as a smooth line over the measured interval and follows it with a critically damped spring, so a picture that is meant to stand still doesn't jolt on every jump. That costs about 0.1 s of lag. The original fold keeps its lead predictor.

## Requirements

- macOS 14.0 or later.
- A MacBook with a lid. The hardware paths need a hinge to read; on a desktop Mac only the interactive preview is available.
- Xcode Command Line Tools (`swiftc`, `xcrun metal`).

---

## Installing

Download `macTilt.dmg` from the [latest release](https://github.com/lqSky7/iphone-duo-macos-animation/releases/latest), open it, and drag **macTilt** into **Applications**.

### macOS will block it twice — this is expected

macTilt is **signed but not notarized**. There is no paid Apple Developer ID behind it, so Gatekeeper cannot verify the app against Apple and refuses it by default. You will hit **two separate blocks**, and you have to clear **both** — clearing the first one does not clear the second.

**1. When opening the DMG**

> *"macTilt.dmg" cannot be opened because Apple cannot check it for malicious software.*

- **Right-click** (or Control-click) the `.dmg` in Finder and choose **Open**, then confirm **Open** again in the dialog.
- If there is no **Open** entry: go to **System Settings → Privacy & Security**, scroll down to the **Security** section, and click **Open Anyway** next to the message about `macTilt.dmg`. Then try opening the DMG again.

**2. When launching the app**

> *"macTilt" cannot be opened because the developer cannot be verified.*

- **Right-click** `macTilt.app` in **Applications** and choose **Open**, then confirm **Open** again.
- If there is no **Open** entry: **System Settings → Privacy & Security → Open Anyway** next to the message about `macTilt.app`, then launch it again.

Both dialogs use roughly the wording above, but Apple changes the exact copy between macOS releases — the route is always the same: right-click **Open**, or **Privacy & Security → Open Anyway**. You only have to do this once per download; after that macOS remembers and the app opens normally.

**Terminal alternative.** If you would rather skip the dialogs, remove the download's quarantine flag instead:

```bash
xattr -dr com.apple.quarantine /Applications/macTilt.app
```

That only clears the flag on your own machine — it does not make the download any more trustworthy to anyone else, so only use it when you trust the source.

### Screen Recording permission

macTilt needs Screen Recording in order to freeze your desktop into the fold. **The animation stays completely off until that permission is granted** — the app draws nothing over your screen, and it never starts a half-rendered or substitute fold in the meantime. Grant it from the onboarding window on first launch, or later from **Settings → Screen Recording Permission**.

---

## Building from Source

Run the automated build script:

```bash
./build.sh
```

Every run of `./build.sh`:

1. Increments the patch version and the build number in `Info.plist`.
2. Compiles the Metal shaders into `default.metallib`.
3. Compiles the Swift application as a universal binary (arm64 + x86_64, targeting macOS 14.0+).
4. Codesigns the app bundle.
5. Creates `build/macTilt.dmg`.
6. Installs directly to `/Applications/macTilt.app`.

---

## Launching

Open the installed application from `/Applications`, or run:

```bash
open /Applications/macTilt.app
```

The menu bar icon shows your current lid status. **Settings** lets you customize the tilt thresholds and preview the animation live.

---

## Credits and Acknowledgements

- **Lid Angle Sensor**: inspired by the hardware reverse-engineering documented in [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) by [@samhenrigold](https://github.com/samhenrigold).
