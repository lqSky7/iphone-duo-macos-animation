import SwiftUI
import AppKit

// Adaptive systemGray6 matching Apple HCI for macOS dark/light mode
private let cardBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 1.0) // macOS systemGray6 dark
        : NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0) // macOS systemGray6 light
}))

private let cardBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1.0, alpha: 0.08)
        : NSColor(white: 0.0, alpha: 0.08)
}))

public struct LiquidGlassSettingsView: View {
    @ObservedObject var settings: AppSettings = AppSettings.shared
    @ObservedObject var updater: UpdateChecker = UpdateChecker.shared
    @State private var copiedResetCommand: Bool = false
    @State private var showingPermissionTroubleshooting: Bool = false
    @State private var demoToken: Int = 0
    private let resetCommand = "tccutil reset ScreenCapture com.lqsky7.mactilt"
    
    public init() {}
    
    public var body: some View {
        // Header and footer are safe-area insets rather than VStack rows, so the
        // card list scrolls BENEATH them and the translucent material has
        // something real to blur as it passes under the bar.
        ScrollView {
            VStack(spacing: 14) {
                // Screen Recording Permission Card
                permissionCard
                
                // Battery & Performance Card
                batteryCard
                
                // Tilt Trigger Angles Card (Hardware LAS) vs Clamshell Opening Card (No LAS)
                if settings.isHardwareSensor {
                    tiltCard
                } else {
                    clamshellOpeningCard
                }
                
                // Display Source & Menu Bar Card
                displaySourceCard
                
                // Animation Physics & Shaders Card
                animationPhysicsCard
                
                // Lock Screen & Sleep Wake Card (Optional)
                lockScreenCard
                
                // Interactive Test Slider Card
                testPreviewCard
                
                // Software Updates & Release Card
                softwareUpdateCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 14)
                
                Divider()
            }
            // Pin the bar (and therefore its material) to the full window width
            // instead of letting it hug the wordmark and the chip, and let the
            // material bleed up under the transparent titlebar.
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, ignoresSafeAreaEdges: .all)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                
                footerBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, ignoresSafeAreaEdges: .all)
        }
        // Fill whatever the window hands us rather than pinning a hard size, so
        // growing the window never leaves dead space around the panel.
        .frame(minWidth: 480, idealWidth: 500, maxWidth: .infinity,
               minHeight: 560, idealHeight: 650, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            settings.refreshPermissions()
        }
        .onDisappear {
            settings.isTestModeActive = false
            settings.testTurnValue = 0.0
            OverlayWindowController.shared.stopOverlay()
        }
    }
    
    // MARK: - Header Bar
    //
    // Deliberately unadorned: the wordmark alone on the left, and a single
    // measurement chip on the right. No icon tile, no tagline — the panel's
    // own sections carry the explanation.
    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("macTilt")
                .font(.system(size: 26, weight: .thin))
                .foregroundStyle(.primary)
            
            Spacer(minLength: 0)
            
            // Live reading chip. The source of the number is named in small
            // translucent type underneath it, so the badge reads as a
            // measurement rather than a status label.
            VStack(alignment: .trailing, spacing: 0) {
                if settings.isHardwareSensor {
                    LiveAngleText()
                        .font(.system(size: 21, weight: .light))
                        .monospacedDigit()
                    Text("LAS")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .opacity(0.6)
                } else {
                    Text("Clamshell")
                        .font(.system(size: 15, weight: .light))
                    Text("No LAS")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(cardBorder, lineWidth: 0.5)
            )
        }
    }
    
    // MARK: - Screen Recording Permission Card
    private var permissionCard: some View {
        HCISectionCard(title: "Screen Recording Permission", icon: "video.badge.checkmark") {
            HStack(spacing: 10) {
                Image(systemName: settings.hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.hasScreenRecordingPermission ? Color.green : Color.orange)
                    .font(.system(size: 15))
                
                Text(settings.hasScreenRecordingPermission ? "Permission Active" : "Permission Required")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                InfoButton("Screen Recording", content: "macTilt requires Screen Recording permission to freeze and fold your active desktop in 3D space as you close the lid. All processing is strictly on-device. Until it is granted, the fold is disabled entirely rather than falling back to a substitute image.")
                
                Spacer()
                
                Button {
                    settings.refreshPermissions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-check permission")
                
                if !settings.hasScreenRecordingPermission {
                    Button("Grant Access") {
                        if !ScreenCapture.shared.requestPermission() {
                            ScreenCapture.shared.openSettings()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            settings.refreshPermissions()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                    Button {
                        showingPermissionTroubleshooting.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Permission troubleshooting")
                    .popover(isPresented: $showingPermissionTroubleshooting, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Permission Troubleshooting")
                                .font(.headline)
                            
                            Text("If already granted in System Settings, macOS requires an app restart to pick up the token.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            HStack {
                                Button("Relaunch App") {
                                    ScreenCapture.shared.relaunchApp()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                
                                Button(copiedResetCommand ? "Copied!" : "Copy Reset Command") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(resetCommand, forType: .string)
                                    copiedResetCommand = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        copiedResetCommand = false
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            Text(resetCommand)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(6)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(14)
                        .frame(width: 300)
                    }
                }
            }

            // Honest first-run state: with the grant missing the fold is
            // deliberately inert (see OverlayWindowController.effectPermitted),
            // so say so rather than letting the user read the silence as a bug.
            if !settings.hasScreenRecordingPermission {
                Text("The fold stays completely off until this is granted — nothing is drawn over your desktop, and the animation never starts half-rendered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - Battery & Power Optimization Card
    private var batteryCard: some View {
        HCISectionCard(title: "Battery & Performance", icon: "battery.100.bolt") {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                
                Text("Zero Idle Battery Impact")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.green)
                
                InfoButton("Battery Efficiency", content: "macTilt is 100% dormant with 0 Hz background polling during normal use. Capture is pre-armed exclusively in the millisecond you start closing your display (~95°). Metal rendering is paused until the clamshell fold begins.")
                
                Spacer()
                
                Text(settings.isScreenCaptureDormant ? "Dormant" : "Pre-Arming")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
        }
    }
    
    // MARK: - Tilt Triggers Card
    private var tiltCard: some View {
        HCISectionCard(title: "Tilt Trigger Thresholds", icon: "angle") {
            VStack(spacing: 12) {
                // Start Angle Slider Row
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Start Fold Angle")
                            .font(.subheadline)
                        
                        InfoButton("Start Angle", content: "The MacBook remains in normal usable state above this angle. Folding begins when closed below it.")
                        
                        Spacer()
                        
                        Text("\(Int(settings.startTiltAngle))°")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.startTiltAngle, in: 40...120, step: 1)
                }
                
                Divider()
                
                // End Angle Slider Row
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Full Fold Angle")
                            .font(.subheadline)
                        
                        InfoButton("Full Fold Angle", content: "The animation scales smoothly across the closing movement and darkens completely into black at this angle.")
                        
                        Spacer()
                        
                        Text("\(Int(settings.endTiltAngle))°")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.endTiltAngle, in: 0...20, step: 1)
                }

                Divider()

                // Auto-release Row (issue #9)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Release When Still")
                            .font(.subheadline)

                        InfoButton("Release When Still", content: "Hold the lid at an angle and stop moving it, and the fold unwinds back to a normal screen. Working angles sit below the start-fold angle, so without this a lid simply left where you use it keeps the desktop folded and blurred until you move or close it. Any movement of the lid takes the fold back.")

                        Spacer()

                        Toggle("", isOn: $settings.autoReleaseFold)
                            .labelsHidden()
                    }

                    if settings.autoReleaseFold {
                        HStack(spacing: 8) {
                            Text("After")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Slider(value: $settings.autoReleaseDelay, in: 0.3...3.0, step: 0.1)

                            Text(String(format: "%.1fs", settings.autoReleaseDelay))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Clamshell Opening Animation Card (Macs without continuous LAS)
    private var clamshellOpeningCard: some View {
        HCISectionCard(title: "Clamshell Opening Animation", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                Text("MacBook Pro 13\" (M1) and similar models utilize Apple's binary clamshell switch instead of continuous hinge sensors. macTilt animates a smooth 120Hz unfold whenever you open the lid from sleep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Opening Duration")
                            .font(.subheadline)
                        
                        InfoButton("Opening Duration", content: "Average human laptop opening duration ranges from 0.8s to 1.1s. Customize how fast or cinematic your unfold animation feels.")
                        
                        Spacer()
                        
                        Text(String(format: "%.2f s", settings.clamshellOpeningDuration))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    
                    Slider(value: $settings.clamshellOpeningDuration, in: 0.4...2.5, step: 0.05)
                        .tint(Color.accentColor)
                    
                    HStack {
                        Text("Snappy (0.6s)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Natural (0.95s)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Cinematic (2.0s)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Divider()
                
                HStack(spacing: 8) {
                    Button(action: {
                        settings.clamshellOpeningDuration = 0.60
                        LidSensor.shared.triggerOpeningPreview()
                    }) {
                        Text("Snappy")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: {
                        settings.clamshellOpeningDuration = 0.95
                        LidSensor.shared.triggerOpeningPreview()
                    }) {
                        Text("Natural")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: {
                        settings.clamshellOpeningDuration = 1.60
                        LidSensor.shared.triggerOpeningPreview()
                    }) {
                        Text("Cinematic")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button(action: {
                        LidSensor.shared.triggerOpeningPreview()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Preview Unfold")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
    
    // MARK: - Display Source & Menu Bar Card
    private var displaySourceCard: some View {
        HCISectionCard(title: "Display & Menu Bar", icon: "display") {
            VStack(spacing: 12) {
                // Display Source Picker Row
                HStack {
                    Text("Screen Source")
                        .font(.subheadline)
                    
                    InfoButton("Screen Source", content: "Choose between live desktop window freezing, current desktop wallpaper, bundled artwork, or a custom image.")
                    
                    Spacer()
                    
                    Picker("", selection: $settings.imageSourceMode) {
                        ForEach(ImageSourceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                
                if settings.imageSourceMode == .customImage {
                    HStack {
                        Text(settings.customImagePath.isEmpty ? "No custom photo selected" : (settings.customImagePath as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose Image...") {
                            selectCustomImage()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                
                if settings.isHardwareSensor {
                    Divider()
                    
                    // Menu Bar Toggle Row
                    HStack {
                        Text("Show Lid Angle in Menu Bar")
                            .font(.subheadline)
                        
                        InfoButton("Menu Bar Display", content: "Displays the live numerical degree readout (e.g. 120°) next to the status icon.")
                        
                        Spacer()
                        
                        Toggle("", isOn: $settings.showAngleInMenuBar)
                            .labelsHidden()
                            .disabled(settings.hideMenuBarIcon)
                    }
                }
                
                Divider()
                
                // Hide Status Icon Row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide Menu Bar Icon")
                            .font(.subheadline)
                        Text("To bring it back, open macTilt again from Applications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    InfoButton("Hide Menu Bar Icon", content: "Removes macTilt from the menu bar completely. The app keeps running and the fold animation keeps working. Reopen macTilt from Applications to show Settings again.")
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.hideMenuBarIcon)
                        .labelsHidden()
                }
            }
        }
    }
    
    // MARK: - Animation Physics Card
    private var animationPhysicsCard: some View {
        HCISectionCard(title: "Physics & Shaders", icon: "slider.horizontal.3") {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Duo Mode")
                            .font(.subheadline)
                        Text("On: fixed Duo look. Off: your own blur, reflection and side blackout below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    InfoButton("Duo Mode", content: "On: the screen looks like it is still standing at 90° as you close the lid — black creeps in from the sides and the blur grows toward the top, with a fixed look. Off: the original macTilt fold, shaped by your Blur Intensity, Specular Reflection and Side Blackout settings.")

                    Spacer()

                    Toggle("", isOn: $settings.duoMode)
                        .labelsHidden()
                }

                Divider()

                // Follow Speed
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Follow Responsiveness")
                            .font(.subheadline)
                        
                        InfoButton(
                            "Follow Responsiveness",
                            content: "How fast the fold chases the physical lid — the response time of the motion smoothing. Lower = softer and more fluid; higher = tighter, more immediate tracking.",
                            demoLabel: "Show me the glide",
                            demo: { demoFold(0.7, animated: false) }
                        )
                        
                        Spacer()
                        
                        Text(String(format: "%.0f", settings.followSpeed))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.followSpeed, in: 6...30, step: 1)
                }
                
                Divider()
                
                // Blur, Specular and Side Blackout shape the original fold only
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Blur Intensity")
                                    .font(.subheadline)
                                InfoButton(
                                    "Blur Intensity",
                                    content: "Depth of the matte defocus that ramps up as the lid tilts — deeper folds and faster closes get softer. The blur is built from the mip chain, so it stays an even, silky matte at every intensity instead of turning grainy frosted glass.",
                                    demoLabel: "Show me at 55% fold",
                                    demo: { demoFold(0.55) }
                                )
                                Spacer()
                                Text(String(format: "%.1fx", settings.blurStrength))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            Slider(value: $settings.blurStrength, in: 0.2...2.0, step: 0.1)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Specular Reflection")
                                    .font(.subheadline)
                                InfoButton(
                                    "Specular Reflection",
                                    content: "A soft cool-white highlight band that sweeps up from the hinge as the screen tilts away — like light catching a glass panel at an angle. The frozen image is never bent or lensed; this only adds the shine. 0 = off (default).",
                                    demoLabel: "Show me at 75% fold",
                                    demo: { demoFold(0.75) }
                                )
                                Spacer()
                                Text(String(format: "%.1fx", settings.reflectionIntensity))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            Slider(value: $settings.reflectionIntensity, in: 0.0...2.5, step: 0.1)
                        }
                    }
                
                    Divider()
                
                    // Side Blackout — horizontal parallax void
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Side Blackout")
                                .font(.subheadline)
                            InfoButton(
                                "Side Blackout",
                                content: "How much black creeps in from the left and right edges as the panel folds away from you. This is the horizontal parallax spread of the folded plane: 0% keeps the frozen frame at its full width, 100% is the physical projection, and higher values let the edges fall away harder.",
                                demoLabel: "Show me at 75% fold",
                                demo: { demoFold(0.75) }
                            )
                            Spacer()
                            Text("\(Int(settings.sideVoidAmount * 100))%")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.sideVoidAmount, in: 0.0...2.0, step: 0.05)
                    }
                }
                .disabled(settings.duoMode)
                .opacity(settings.duoMode ? 0.4 : 1.0)
            }
        }
    }
    
    // MARK: - Lock Screen & Sleep Wake Card (Optional)
    private var lockScreenCard: some View {
        HCISectionCard(title: "Lock Screen & Sleep Wake", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("High Priority Display Level")
                            .font(.subheadline)
                        Text("Elevates overlay priority to display during wake transitions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    InfoButton("Lock Screen Wake", content: "macOS isolates the password Lock Screen for security. To see the animation unfold dynamically on wake, set a 1-minute password grace period in System Settings > Lock Screen, or use Apple Watch Auto-Unlock.")
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableLockScreenPriority)
                        .labelsHidden()
                }
            }
        }
    }
    
    // MARK: - Test Preview Card
    private var testPreviewCard: some View {
        HCISectionCard(title: "Interactive Preview", icon: "play.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Preview Animation")
                        .font(.subheadline)
                    
                    InfoButton("Interactive Preview", content: "Scrub and inspect the fold on your screen without physically moving the lid.")
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.isTestModeActive)
                        .labelsHidden()
                        .onChange(of: settings.isTestModeActive) { _, newValue in
                            if !newValue {
                                // Immediately clear turn value so the overlay hides at once
                                settings.testTurnValue = 0.0
                            }
                        }
                }
                
                if settings.isTestModeActive {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Fold Progress")
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(settings.testTurnValue * 100))%")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.testTurnValue, in: 0.0...1.0) { isEditing in
                            if isEditing {
                                settings.isTestModeActive = true
                                OverlayWindowController.shared.captureScreenAsync()
                            } else {
                                // Stop the overlay on screen as soon as the user leaves the slider
                                withAnimation(.easeOut(duration: 0.25)) {
                                    settings.testTurnValue = 0.0
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    if settings.testTurnValue == 0.0 {
                                        settings.isTestModeActive = false
                                        OverlayWindowController.shared.stopOverlay()
                                    }
                                }
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }
    
    // MARK: - Software Updates Card
    private var softwareUpdateCard: some View {
        HCISectionCard(title: "Software Updates", icon: "arrow.triangle.2.circlepath.circle") {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current Version: v\(updater.currentVersion) (Build \(updater.currentBuild))")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        if updater.isChecking {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking GitHub for updates...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if updater.updateAvailable {
                            Text("New version available: \(updater.latestVersion)")
                                .font(.caption)
                                .foregroundStyle(Color.green)
                                .fontWeight(.semibold)
                        } else if updater.hasChecked {
                            Text(updater.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Check for newer releases published on GitHub.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        updater.checkForUpdates(userInitiated: true)
                    }) {
                        HStack(spacing: 4) {
                            if updater.isChecking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Check for Updates")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updater.isChecking)
                }
                
                if updater.updateAvailable {
                    Divider()
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(updater.latestVersion) Ready to Install")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Download the latest universal DMG installer directly from GitHub Releases.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Download Update (.dmg)") {
                            updater.openLatestRelease()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                
                Divider()
                
                Toggle(isOn: $settings.automaticallyCheckForUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically Check for Updates")
                            .font(.subheadline)
                        Text("Silently checks GitHub releases in the background on startup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
    
    // MARK: - Bottom Footer Bar
    private var footerBar: some View {
        HStack {
            Button("Reset to Defaults") {
                settings.startTiltAngle = 115.0
                settings.endTiltAngle = 3.0
                settings.followSpeed = 16.0
                settings.imageSourceMode = .liveCapture
                settings.blurStrength = 0.5
                settings.reflectionIntensity = 0.0
                settings.duoMode = true
                settings.showAngleInMenuBar = true
                settings.isTestModeActive = false
                settings.testTurnValue = 0.0
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            Button("Welcome Guide") {
                MenuBarController.shared.openOnboardingWindow()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            Spacer()
            
            Button("Done") {
                settings.isTestModeActive = false
                settings.testTurnValue = 0.0
                OverlayWindowController.shared.stopOverlay()
                NSApp.keyWindow?.orderOut(nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
        }
    }
    
    /// Live demonstration: shows the fullscreen fold at a representative
    /// progress for a few seconds, then eases out. The popover closes first
    /// so the demo is visible (the overlay covers all windows).
    private func demoFold(_ turn: Double, animated: Bool = true) {
        demoToken += 1
        let token = demoToken
        settings.isTestModeActive = true
        OverlayWindowController.shared.captureScreenAsync()
        if animated {
            withAnimation(.easeInOut(duration: 0.5)) {
                settings.testTurnValue = turn
            }
        } else {
            settings.testTurnValue = turn
        }
        let capturedSettings = settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            guard token == self.demoToken else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                capturedSettings.testTurnValue = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard token == self.demoToken else { return }
                if capturedSettings.testTurnValue == 0.0 {
                    capturedSettings.isTestModeActive = false
                    OverlayWindowController.shared.stopOverlay()
                }
            }
        }
    }

    private func selectCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.customImagePath = url.path
        }
    }
}

// MARK: - Apple HCI Grouped Section Card Component
private struct HCISectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card Title Label
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
            
            // Card Content Container
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(cardBorder, lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Apple HCI Info Popover Button
private struct InfoButton: View {
    let title: String
    let content: String
    var demoLabel: String? = nil
    var demo: (() -> Void)? = nil
    @State private var isShowing: Bool = false

    init(_ title: String = "", content: String, demoLabel: String? = nil, demo: (() -> Void)? = nil) {
        self.title = title
        self.content = content
        self.demoLabel = demoLabel
        self.demo = demo
    }

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                if !title.isEmpty {
                    Text(title)
                        .font(.headline)
                }
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                if let demoLabel, let demo {
                    Button {
                        isShowing = false
                        demo()
                    } label: {
                        Label(demoLabel, systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}

/// Only this text re-renders when the lid moves, not the whole panel.
private struct LiveAngleText: View {
    @ObservedObject var live = LiveLidAngle.shared
    var body: some View { Text("\(Int(live.angle))°") }
}
