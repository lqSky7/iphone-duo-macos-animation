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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: settings.hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(settings.hasScreenRecordingPermission ? Color.green : Color.orange)
                        .font(.system(size: 16))
                    
                    Text(settings.hasScreenRecordingPermission ? "Permission Active: Open windows will fold in real time." : "Permission Required: Open windows cannot be captured.")
                        .font(.subheadline)
                        .foregroundStyle(settings.hasScreenRecordingPermission ? .primary : .secondary)
                    
                    Spacer()
                    
                    Button {
                        settings.refreshPermissions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Re-check screen recording permission")
                    
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
                    }
                }
                
                if !settings.hasScreenRecordingPermission {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Granted in Settings but still showing as required?")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            Button("Relaunch App") {
                                ScreenCapture.shared.relaunchApp()
                            }
                            .buttonStyle(.glass)
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
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
    
    // MARK: - Battery & Power Optimization Card
    private var batteryCard: some View {
        HCISectionCard(title: "Battery & Performance", icon: "battery.100.bolt") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Zero Idle Battery Impact")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.green)
                    Spacer()
                    Text(settings.isScreenCaptureDormant ? "Capture Engine: Dormant" : "Capture Engine: Pre-Arming")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text("macTilt does not poll or record in the background while you work. The screen capture engine remains 100% dormant and is pre-armed strictly during the physical closing motion (~95°). Metal rendering is paused until the clamshell fold begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                
                Divider()
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background Polling")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("0 Hz (Event-Driven)")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idle GPU / CPU Impact")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("0.0%")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Pre-Arm Mechanism")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Hardware Angle Delta")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
        }
    }
    
    // MARK: - Tilt Triggers Card
    private var tiltCard: some View {
        HCISectionCard(title: "Tilt Trigger Thresholds", icon: "angle") {
            VStack(spacing: 14) {
                // Start Angle Slider Row
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Start Closing Animation At")
                            .font(.subheadline)
                        Spacer()
                        Text("\(Int(settings.startTiltAngle))°")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.startTiltAngle, in: 40...120, step: 1)
                    Text("The MacBook remains in normal usable state above this angle. Folding begins when closed below it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                // End Angle Slider Row
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Fully Folded (Void) At")
                            .font(.subheadline)
                        Spacer()
                        Text("\(Int(settings.endTiltAngle))°")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.endTiltAngle, in: 0...20, step: 1)
                    Text("The animation smoothly scales across the closing movement and darkens completely at this angle.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    Spacer()
                    Picker("", selection: $settings.imageSourceMode) {
                        ForEach(ImageSourceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Lid Angle in Menu Bar")
                            .font(.subheadline)
                        Text("Show degree reading (e.g. \(Int(settings.currentLidAngle))°) next to the status icon.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preview Animation")
                            .font(.subheadline)
                        Text("Scrub and inspect the fold on your screen without moving the lid.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
