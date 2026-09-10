import SwiftUI

public struct LiquidGlassControlPanel: View {
    @ObservedObject var settings: AppSettings = AppSettings.shared
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 20) {
            // Header with Sensor Status using .glassEffect
            headerSection
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            
            // Customization Options
            ScrollView {
                VStack(spacing: 16) {
                    // Tilt Trigger Settings (User requirement: when to start animation based on tilt)
                    tiltSection
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                    
                    // Animation & Hinge Controls
                    animationSection
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                    
                    // Image Source Controls
                    imageSourceSection
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                    
                    // Interactive Test Slider
                    interactiveTestSection
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 4)
            }
            
            // Footer Action Bar
            footerSection
        }
        .padding(20)
        .frame(width: 480, height: 640)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
    
    // MARK: - Header
    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .frame(width: 52, height: 52)
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
                    
                    Text(settings.isSensorConnected ? "Sensor Active: \(Int(settings.currentLidAngle))°" : "Sensor Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(settings.currentLidAngle))°")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(angleStatusDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
    
    private var angleStatusDescription: String {
        if settings.currentLidAngle >= settings.startTiltAngle {
            return "Flat / Fully Open"
        } else if settings.currentLidAngle <= settings.endTiltAngle {
            return "Folded / Closed"
        } else {
            let pct = Int(settings.normalizedTurn(for: settings.currentLidAngle) * 100)
            return "Folding (\(pct)%)"
        }
    }
    
    // MARK: - Tilt Triggers (Start & End tilt angles)
    private var tiltSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Tilt Thresholds", systemImage: "angle")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Start Animation At:")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(settings.startTiltAngle))°")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
                Slider(value: $settings.startTiltAngle, in: 60...135, step: 1)
                Text("Animation triggers when MacBook lid closes below this angle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Full Fold (Dark Void) At:")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(settings.endTiltAngle))°")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
                Slider(value: $settings.endTiltAngle, in: 0...45, step: 1)
                Text("Screen becomes completely folded and dark at this angle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
    
    // MARK: - Animation & Hinge Options
    private var animationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Animation & Physics", systemImage: "sparkles")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Hinge Style")
                    .font(.subheadline)
                
                Picker("Hinge Style", selection: $settings.hingeMode) {
                    ForEach(HingeMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Follow Speed (Easing):")
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
        .padding(16)
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
        .padding(16)
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
                        Text("Fold Turn:")
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
                Text("Enable to preview the full-screen fold animation without moving the lid.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
    
    // MARK: - Footer
    private var footerSection: some View {
        HStack {
            Button("Reset Defaults") {
                settings.startTiltAngle = 110.0
                settings.endTiltAngle = 15.0
                settings.followSpeed = 16.0
                settings.hingeMode = .clamshell
                settings.imageSourceMode = .liveCapture
                settings.blurStrength = 1.0
                settings.reflectionIntensity = 1.0
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
