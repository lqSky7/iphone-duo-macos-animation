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
    @State private var isScreenSaverInstalled: Bool = false
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
                    
                    // Lock Screen & Sleep Wake Card (Optional)
                    lockScreenCard
                    
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
            checkSaverInstalled()
        }
        .onDisappear {
            settings.isTestModeActive = false
            settings.testTurnValue = 0.0
            OverlayWindowController.shared.stopOverlay()
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
                
                Text("MacBook 合盖折叠动画")
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
            return "正常使用（已开盖）"
        } else if settings.currentLidAngle <= settings.endTiltAngle {
            return "已合盖"
        } else {
            let pct = Int(settings.normalizedTurn(for: settings.currentLidAngle) * 100)
            return "折叠中（\(pct)%）"
        }
    }
    
    // MARK: - Screen Recording Permission Card
    private var permissionCard: some View {
        HCISectionCard(title: "屏幕录制权限", icon: "video.badge.checkmark") {
            HStack(spacing: 10) {
                Image(systemName: settings.hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.hasScreenRecordingPermission ? Color.green : Color.orange)
                    .font(.system(size: 15))
                
                Text(settings.hasScreenRecordingPermission ? "已授权" : "需要授权")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                InfoButton("屏幕录制", content: "macTilt 需要屏幕录制权限，才能在合盖时捕获当前桌面并呈现 3D 折叠动画。所有处理均在本机完成。")
                
                Spacer()
                
                Button {
                    settings.refreshPermissions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("重新检查权限")
                
                if !settings.hasScreenRecordingPermission {
                    Button("前往授权") {
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
                    .help("权限问题排查")
                    .popover(isPresented: $showingPermissionTroubleshooting, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("权限问题排查")
                                .font(.headline)
                            
                            Text("如果已在系统设置中授权，请重新启动应用，让 macOS 应用新的权限。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            HStack {
                                Button("重新启动应用") {
                                    ScreenCapture.shared.relaunchApp()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                
                                Button(copiedResetCommand ? "已复制！" : "复制重置命令") {
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
        }
    }
    
    // MARK: - Battery & Power Optimization Card
    private var batteryCard: some View {
        HCISectionCard(title: "电池与性能", icon: "battery.100.bolt") {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                
                Text("闲置时零额外耗电")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.green)
                
                InfoButton("节能说明", content: "正常使用时，macTilt 完全休眠，后台轮询频率为 0 Hz。仅在开始合盖（约 95°）时准备屏幕捕获；折叠动画开始前，Metal 渲染保持暂停。")
                
                Spacer()
                
                Text(settings.isScreenCaptureDormant ? "休眠中" : "准备捕获")
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
        HCISectionCard(title: "合盖触发角度", icon: "angle") {
            VStack(spacing: 12) {
                // Start Angle Slider Row
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("开始折叠角度")
                            .font(.subheadline)
                        
                        InfoButton("起始角度", content: "屏幕开合角度大于此值时，MacBook 保持正常使用状态。合盖至此角度以下时，画面会停留在这个角度，屏幕像玻璃一样从它前面合上，离铰链越远越暗、越模糊。")
                        
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
                        Text("完全折叠角度")
                            .font(.subheadline)
                        
                        InfoButton("完全折叠角度", content: "动画随合盖动作平滑变化，到达此角度时，画面完全变黑。")
                        
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
        HCISectionCard(title: "显示与菜单栏", icon: "display") {
            VStack(spacing: 12) {
                // Display Source Picker Row
                HStack {
                    Text("画面来源")
                        .font(.subheadline)
                    
                    InfoButton("画面来源", content: "选择实时屏幕捕获、当前桌面壁纸、内置图片或自定义图片作为动画画面。")
                    
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
                        Text(settings.customImagePath.isEmpty ? "尚未选择自定义图片" : (settings.customImagePath as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("选择图片…") {
                            selectCustomImage()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                
                Divider()
                
                // Menu Bar Toggle Row
                HStack {
                    Text("在菜单栏显示开合角度")
                        .font(.subheadline)
                    
                    InfoButton("菜单栏显示", content: "在状态图标旁实时显示屏幕开合角度（例如 120°）。")
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.showAngleInMenuBar)
                        .labelsHidden()
                }
            }
        }
    }
    
    // MARK: - Animation Physics Card
    private var animationPhysicsCard: some View {
        HCISectionCard(title: "动画与视觉效果", icon: "slider.horizontal.3") {
            VStack(spacing: 12) {
                // Follow Speed
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("跟随灵敏度")
                            .font(.subheadline)
                        
                        InfoButton("跟随速度", content: "控制画面折叠的平滑跟随速度。")
                        
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
                            Text("模糊强度")
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
                            Text("玻璃反射")
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
    
    // MARK: - Lock Screen & Sleep Wake Card (Optional)
    private var lockScreenCard: some View {
        HCISectionCard(title: "锁屏与睡眠唤醒", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("锁屏开盖动画")
                            .font(.subheadline)
                        Text(settings.lockScreenStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("锁定期间持续跟随开合角度，可反复合盖、开盖，无时间限制。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    InfoButton("锁屏唤醒", content: "通过系统锁屏显示空间呈现开盖动画。锁定期间使用壁纸，不显示桌面快照；动画不接收键盘和鼠标输入。此功能使用私有接口，系统更新后可能需要适配。")
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableLockScreenPriority)
                        .labelsHidden()
                        .disabled(LockScreenSpace.isSIPEnabled)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("配套屏幕保护程序（.saver）")
                                .font(.subheadline)
                            Text(isScreenSaverInstalled ? "已安装至 ~/Library/Screen Savers/macTilt.saver" : "直接在 macOS 密码锁定屏幕上呈现合盖折叠动画。")
                                .font(.caption)
                                .foregroundStyle(isScreenSaverInstalled ? Color.green : Color.secondary)
                        }
                        
                        InfoButton("锁屏配套组件", content: "Apple 允许屏幕保护程序直接在密码锁定屏幕上渲染。安装此组件后，macTilt 可向锁屏实时传递开合角度，闲置时不增加耗电。")
                        
                        Spacer()
                    }
                    
                    HStack(spacing: 8) {
                        Button(isScreenSaverInstalled ? "重新安装组件" : "安装配套组件（.saver）") {
                            installScreenSaver()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        if isScreenSaverInstalled {
                            Button("测试屏幕保护程序") {
                                testScreenSaver()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button("打开设置") {
                                openScreenSaverSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Test Preview Card
    private var testPreviewCard: some View {
        HCISectionCard(title: "交互预览", icon: "play.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("预览动画")
                        .font(.subheadline)
                    
                    InfoButton("交互预览", content: "拖动滑块即可在屏幕上预览折叠效果，无需实际开合屏幕。")
                    
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
                            Text("折叠进度")
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
    
    // MARK: - Bottom Footer Bar
    private var footerBar: some View {
        HStack {
            Button("恢复默认设置") {
                settings.startTiltAngle = 115.0
                settings.endTiltAngle = 3.0
                settings.followSpeed = 16.0
                settings.imageSourceMode = .liveCapture
                settings.blurStrength = 0.5
                settings.reflectionIntensity = 0.0
                settings.showAngleInMenuBar = true
                settings.isTestModeActive = false
                settings.testTurnValue = 0.0
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            Button("使用指南") {
                MenuBarController.shared.openOnboardingWindow()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            Spacer()
            
            Button("完成") {
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
    
    private func selectCustomImage() {
        let panel = NSOpenPanel()
        panel.title = "选择自定义图片"
        panel.message = "请选择用于合盖动画的图片。"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.customImagePath = url.path
        }
    }
    
    private func checkSaverInstalled() {
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/macTilt.saver")
        isScreenSaverInstalled = FileManager.default.fileExists(atPath: dest.path)
    }
    
    private func installScreenSaver() {
        let destDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("macTilt.saver")
        
        guard let srcUrl = Bundle.main.url(forResource: "macTilt", withExtension: "saver") else { return }
        
        if FileManager.default.fileExists(atPath: srcUrl.path) {
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: srcUrl, to: dest)
                checkSaverInstalled()
                openScreenSaverSettings()
            } catch {
                print("[macTilt] Error installing screen saver: \(error)")
            }
        }
    }
    
    private func testScreenSaver() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "/System/Library/CoreServices/ScreenSaverEngine.app"]
        try? task.run()
    }
    
    private func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.desktopscreeneffect?ScreenSaver") {
            NSWorkspace.shared.open(url)
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
