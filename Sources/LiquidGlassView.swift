import SwiftUI

public struct LiquidGlassControlPanel: View {
    @ObservedObject var settings: AppSettings = AppSettings.shared
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 16) {
            // Header with Sensor Status
            headerSection
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
            
            // Screen Recording Permission Banner
            permissionSection
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            
            // Customization Options ScrollView
            ScrollView {
                VStack(spacing: 14) {
                    // Menu Bar Display Settings (Option to hide lid sensor value from menu bar)
                    menuBarSection
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                    
                    // Tilt Trigger Thresholds (Configured for full closing arc)
                    tiltSection
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                    
                    // Animation & Physics Controls
                    animationSection
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                    
                    // Image Source Controls
                    imageSourceSection
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                    
                    // Interactive Test Slider
                    interactiveTestSection
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 2)
            }
            
            // Footer Action Bar
            footerSection
        }
        .padding(20)
        .frame(width: 480, height: 720)
        // Clean, solid macOS window background (NOT glass, for crisp contrast and readability)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            settings.refreshPermissions()
        }
    }
    
    // MARK: - Header
    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .frame(width: 50, height: 50)
                    .glassEffect(.clear, in: Circle())
                
                Image(systemName: settings.isSensorConnected ? "laptopcomputer" : "laptopcomputer.trianglebadge.exclamationmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(settings.isSensorConnected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("iPhone Duo macOS")
                    .font(.headline)
                    .fontWeight(.bold)
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(settings.isSensorConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    
                    Text(settings.isSensorConnected ? "Sensor Connected: \(Int(settings.currentLidAngle))°" : "Sensor Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(settings.currentLidAngle))°")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(angleStatusDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
    
    private var angleStatusDescription: String {
        if settings.currentLidAngle >= settings.startTiltAngle {
            return "Using Mac (Idle)"
        } else if settings.currentLidAngle <= settings.endTiltAngle {
            return "Lid Closed (Dark)"
        } else if settings.isClosing {
            let pct = Int(settings.normalizedTurn(for: settings.currentLidAngle, isLidClosing: true) * 100)
            return "Closing (\(pct)%)"
        } else {
            return "Opening (Idle)"
        }
    }
    
    // MARK: - Screen Recording Permission Section
    @State private var copiedResetCommand: Bool = false
    private let resetCommand = "tccutil reset ScreenCapture com.lqsky7.iphoneduo"
    
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: settings.hasScreenRecordingPermission ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.hasScreenRecordingPermission ? Color.green : Color.orange)
                    .font(.system(size: 20))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.hasScreenRecordingPermission ? "Screen Recording Permission Active" : "Screen Recording Permission Required")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(settings.hasScreenRecordingPermission ? "Live screen capture is active." : "Required to capture and fold open windows.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if !settings.hasScreenRecordingPermission {
                    HStack(spacing: 8) {
                        Button {
                            settings.refreshPermissions()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Refresh permission status")
                        
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
                } else {
                    Button {
                        settings.refreshPermissions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Refresh permission status")
                }
            }
            
            Divider()
            
            // TCC Cache Reset and Relaunch Helper
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Permission not reflecting?")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button("Relaunch App") {
                        ScreenCapture.shared.relaunchApp()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resetCommand, forType: .string)
                        copiedResetCommand = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            copiedResetCommand = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedResetCommand ? "checkmark" : "doc.on.doc")
                            Text(copiedResetCommand ? "Copied!" : "Copy Reset Command")
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
                    .background(Color.black.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                Text("macOS requires an app relaunch after granting access in System Settings. If still not detecting, copy and run the reset command in Terminal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
    
    // MARK: - Menu Bar Display Section
    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Menu Bar Display", systemImage: "menubar.rectangle")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Toggle("Show Lid Sensor Angle in Menu Bar", isOn: $settings.showAngleInMenuBar)
                .font(.subheadline)
            
            Text(settings.showAngleInMenuBar ? "Displays the live angle (e.g. \(Int(settings.currentLidAngle))°) next to the menu bar icon." : "Icon-only mode. The numerical sensor degree value is hidden.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
    
    // MARK: - Tilt Triggers (Start & End tilt angles)
    private var tiltSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Tilt Trigger Thresholds", systemImage: "angle")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Start Closing Animation At:")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(settings.startTiltAngle))°")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
                Slider(value: $settings.startTiltAngle, in: 40...120, step: 1)
                Text("Normal usage remains completely idle above \(Int(settings.startTiltAngle))°. Animation triggers when closing below this angle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Fully Folded (Dark Void) At:")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(settings.endTiltAngle))°")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
                Slider(value: $settings.endTiltAngle, in: 0...20, step: 1)
                Text("Animation progresses through the closing arc and reaches complete dark fold at \(Int(settings.endTiltAngle))°.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
    
    // MARK: - Animation & Physics Options
    private var animationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Animation Physics & Effects", systemImage: "sparkles")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Follow Responsiveness:")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.1f", settings.followSpeed))
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
                Slider(value: $settings.followSpeed, in: 6...30, step: 1)
            }
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blur: \(String(format: "%.1fx", settings.blurStrength))")
                        .font(.caption)
                    Slider(value: $settings.blurStrength, in: 0.2...2.0, step: 0.1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Glass: \(String(format: "%.1fx", settings.reflectionIntensity))")
                        .font(.caption)
                    Slider(value: $settings.reflectionIntensity, in: 0.0...2.5, step: 0.1)
                }
            }
        }
        .padding(14)
    }
    
    // MARK: - Image Source
    private var imageSourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Display Source", systemImage: "display")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Picker("Source", selection: $settings.imageSourceMode) {
                ForEach(ImageSourceMode.allCases) { src in
                    Text(src.title).tag(src)
                }
            }
            .pickerStyle(.menu)
            
            if settings.imageSourceMode == .customImage {
                HStack {
                    Text(settings.customImagePath.isEmpty ? "No file selected" : (settings.customImagePath as NSString).lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Image...") {
                        selectCustomImage()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(14)
    }
    
    // MARK: - Interactive Test Slider
    private var interactiveTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Test Preview Slider", systemImage: "slider.horizontal.below.rectangle")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Toggle("", isOn: $settings.isTestModeActive)
                    .labelsHidden()
            }
            
            if settings.isTestModeActive {
                VStack(spacing: 6) {
                    HStack {
                        Text("Fold Turn (0% to 100%):")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(settings.testTurnValue * 100))%")
                            .font(.caption)
                            .fontWeight(.bold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.testTurnValue, in: 0.0...1.0)
                }
                .transition(.opacity)
            } else {
                Text("Enable to preview the up-to-down closing animation smoothly across your screen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
    
    // MARK: - Footer
    private var footerSection: some View {
        HStack {
            Button("Reset Defaults") {
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
            
            Spacer()
            
            Button("Done") {
                NSApp.keyWindow?.orderOut(nil)
            }
            .buttonStyle(.glassProminent)
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
