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

public struct LiquidGlassControlPanel: View {
    @ObservedObject var settings: AppSettings = AppSettings.shared
    @State private var copiedResetCommand: Bool = false
    @State private var showingPermissionTroubleshooting: Bool = false
    private let resetCommand = "tccutil reset ScreenCapture com.lqsky7.mactilt"
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // Top Header Bar
            headerBar
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
            
            Divider()
            
            // Main Settings Scroll Area (All cards match exactly in horizontal width)
            ScrollView {
                VStack(spacing: 14) {
                    // Screen Recording Permission Card
                    permissionCard
                    
                    // Battery & Performance Card
                    batteryCard
                    
                    // Tilt Trigger Angles Card
                    tiltCard
                    
                    // Display Source & Menu Bar Card
                    displaySourceCard
                    
                    // Animation Physics & Shaders Card
                    animationPhysicsCard
                    
                    // Interactive Test Slider Card
                    testPreviewCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            
            Divider()
            
            // Bottom Action Footer
            footerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 500, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            settings.refreshPermissions()
        }
    }
    
    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cardBackground)
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(cardBorder, lineWidth: 0.5)
                    )
                
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(settings.isSensorConnected ? Color.accentColor : Color.secondary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("macTilt")
                    .font(.title3)
                    .fontWeight(.bold)
                
                Text("MacBook Clamshell Fold Animation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Real-time Hardware Angle Badge
            HStack(spacing: 8) {
                Circle()
                    .fill(settings.isSensorConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(settings.currentLidAngle))°")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(angleStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(cardBorder, lineWidth: 0.5)
            )
        }
    }
    
    private var angleStatusText: String {
        if settings.currentLidAngle >= settings.startTiltAngle {
            return "Using Mac (Idle)"
        } else if settings.currentLidAngle <= settings.endTiltAngle {
            return "Lid Closed"
        } else if settings.isClosing {
            let pct = Int(settings.normalizedTurn(for: settings.currentLidAngle, isLidClosing: true) * 100)
            return "Closing (\(pct)%)"
        } else {
            return "Opening (Idle)"
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
                
                InfoButton("Screen Recording", content: "macTilt requires Screen Recording permission to freeze and fold your active desktop in 3D space as you close the lid. All processing is strictly on-device.")
                
                Spacer()
                
                Button {
                    settings.refreshPermissions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
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
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    
                    Button {
                        showingPermissionTroubleshooting.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.glass)
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
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                                
                                Button(copiedResetCommand ? "Copied!" : "Copy Reset Command") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(resetCommand, forType: .string)
                                    copiedResetCommand = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        copiedResetCommand = false
                                    }
                                }
                                .buttonStyle(.glass)
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
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                
                Divider()
                
                // Menu Bar Toggle Row
                HStack {
                    Text("Show Lid Angle in Menu Bar")
                        .font(.subheadline)
                    
                    InfoButton("Menu Bar Display", content: "Displays the live numerical degree readout (e.g. 120°) next to the status icon.")
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.showAngleInMenuBar)
                        .labelsHidden()
                }
            }
        }
    }
    
    // MARK: - Animation Physics Card
    private var animationPhysicsCard: some View {
        HCISectionCard(title: "Physics & Shaders", icon: "slider.horizontal.3") {
            VStack(spacing: 12) {
                // Follow Speed
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Follow Responsiveness")
                            .font(.subheadline)
                        
                        InfoButton("Follow Speed", content: "Controls the exponential smoothing physics of the display turn.")
                        
                        Spacer()
                        
                        Text(String(format: "%.0f", settings.followSpeed))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.followSpeed, in: 6...30, step: 1)
                }
                
                Divider()
                
                // Blur and Glass Dual Sliders
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Blur Intensity")
                                .font(.subheadline)
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
                            Text("Glass Reflection")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.1fx", settings.reflectionIntensity))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.reflectionIntensity, in: 0.0...2.5, step: 0.1)
                    }
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
                        Slider(value: $settings.testTurnValue, in: 0.0...1.0)
                    }
                    .transition(.opacity)
                }
            }
        }
    }
    
    // MARK: - Bottom Footer Bar
    private var footerBar: some View {
        HStack {
            Button("Reset to Defaults") {
                settings.startTiltAngle = 80.0
                settings.endTiltAngle = 3.0
                settings.followSpeed = 16.0
                settings.imageSourceMode = .liveCapture
                settings.blurStrength = 1.0
                settings.reflectionIntensity = 1.0
                settings.showAngleInMenuBar = true
                settings.isTestModeActive = false
                settings.testTurnValue = 0.0
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            
            Button("Welcome Guide") {
                MenuBarController.shared.openOnboardingWindow()
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            
            Spacer()
            
            Button("Done") {
                NSApp.keyWindow?.orderOut(nil)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
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
    @State private var isShowing: Bool = false
    
    init(_ title: String = "", content: String) {
        self.title = title
        self.content = content
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
            VStack(alignment: .leading, spacing: 6) {
                if !title.isEmpty {
                    Text(title)
                        .font(.headline)
                }
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(12)
            .frame(width: 260)
        }
    }
}

