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
                
                Text(tr("MacBook 合盖折叠动画", "Lid fold animation for MacBook"))
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
            return tr("正常使用（已开盖）", "In use (lid open)")
        } else if settings.currentLidAngle <= settings.endTiltAngle {
            return tr("已合盖", "Lid closed")
        } else {
            let pct = Int(settings.normalizedTurn(for: settings.currentLidAngle) * 100)
            return tr("折叠中（\(pct)%）", "Folding (\(pct)%)")
        }
    }
    
    // MARK: - Screen Recording Permission Card
    private var permissionCard: some View {
        HCISectionCard(title: tr("屏幕录制权限", "Screen Recording"), icon: "video.badge.checkmark") {
            HStack(spacing: 10) {
                Image(systemName: settings.hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.hasScreenRecordingPermission ? Color.green : Color.orange)
                    .font(.system(size: 15))
                
                Text(settings.hasScreenRecordingPermission ? tr("已授权", "Granted") : tr("需要授权", "Not Granted"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                InfoButton(tr("屏幕录制", "Screen Recording"), content: tr("macTilt 需要屏幕录制权限，才能在合盖时捕获当前桌面并呈现 3D 折叠动画。所有处理均在本机完成。", "macTilt needs Screen Recording permission to capture your desktop when the lid closes and show it as a 3D fold. Everything is processed on this Mac."))
                
                Spacer()
                
                Button {
                    settings.refreshPermissions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(tr("重新检查权限", "Check Again"))
                
                if !settings.hasScreenRecordingPermission {
                    Button(tr("前往授权", "Grant Access")) {
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
                    .help(tr("权限问题排查", "Troubleshooting"))
                    .popover(isPresented: $showingPermissionTroubleshooting, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tr("权限问题排查", "Troubleshooting"))
                                .font(.headline)
                            
                            Text(tr("如果已在系统设置中授权，请重新启动应用，让 macOS 应用新的权限。", "If you already allowed access in System Settings, relaunch the app so macOS applies the permission."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            HStack {
                                Button(tr("重新启动应用", "Relaunch App")) {
                                    ScreenCapture.shared.relaunchApp()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                
                                Button(copiedResetCommand ? tr("已复制！", "Copied!") : tr("复制重置命令", "Copy Reset Command")) {
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
        HCISectionCard(title: tr("电池与性能", "Battery & Performance"), icon: "battery.100.bolt") {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                
                Text(tr("闲置时零额外耗电", "No extra power use when idle"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.green)
                
                InfoButton(tr("节能说明", "Power Saving"), content: tr("正常使用时，macTilt 完全休眠，后台轮询频率为 0 Hz。仅在开始合盖（约 95°）时准备屏幕捕获；折叠动画开始前，Metal 渲染保持暂停。", "During normal use, macTilt sleeps with 0 Hz background polling. It prepares a screen capture only as the lid starts to close (around 95°), and Metal rendering stays paused until the fold begins."))
                
                Spacer()
                
                Text(settings.isScreenCaptureDormant ? tr("休眠中", "Sleeping") : tr("准备捕获", "Preparing"))
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
        HCISectionCard(title: tr("合盖触发角度", "Fold Angles"), icon: "angle") {
            VStack(spacing: 12) {
                // Start Angle Slider Row
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tr("开始折叠角度", "Start Angle"))
                            .font(.subheadline)
                        
                        InfoButton(tr("起始角度", "Start Angle"), content: tr("屏幕开合角度大于此值时，MacBook 保持正常使用状态。合盖至此角度以下时，画面会停留在这个角度，屏幕像玻璃一样从它前面合上，离铰链越远越暗、越模糊。", "Above this angle, your MacBook works as usual. Below it, the picture stays at this angle while the screen closes in front of it like glass, growing darker and blurrier away from the hinge."))
                        
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
                        Text(tr("完全折叠角度", "End Angle"))
                            .font(.subheadline)
                        
                        InfoButton(tr("完全折叠角度", "End Angle"), content: tr("动画随合盖动作平滑变化，到达此角度时，画面完全变黑。", "The animation follows the lid smoothly and is fully black at this angle."))
                        
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
        HCISectionCard(title: tr("显示与菜单栏", "Display & Menu Bar"), icon: "display") {
            VStack(spacing: 12) {
                // Display Source Picker Row
                HStack {
                    Text(tr("画面来源", "Image Source"))
                        .font(.subheadline)
                    
                    InfoButton(tr("画面来源", "Image Source"), content: tr("选择实时屏幕捕获、当前桌面壁纸、内置图片或自定义图片作为动画画面。", "Use a live screen capture, the current desktop wallpaper, the bundled artwork, or a custom image for the animation."))
                    
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
                        Text(settings.customImagePath.isEmpty ? tr("尚未选择自定义图片", "No custom image selected") : (settings.customImagePath as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(tr("选择图片…", "Choose Image…")) {
                            selectCustomImage()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                
                Divider()
                
                // Menu Bar Toggle Row
                HStack {
                    Text(tr("在菜单栏显示开合角度", "Show Lid Angle in Menu Bar"))
                        .font(.subheadline)
                    
                    InfoButton(tr("菜单栏显示", "Menu Bar"), content: tr("在状态图标旁实时显示屏幕开合角度（例如 120°）。", "Shows the live lid angle next to the status icon, for example 120°."))
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.showAngleInMenuBar)
                        .labelsHidden()
                }

                Divider()

                // Language Row
                HStack {
                    Text(tr("语言", "Language"))
                        .font(.subheadline)

                    Spacer()

                    Picker("", selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
        }
    }
    
    // MARK: - Animation Physics Card
    private var animationPhysicsCard: some View {
        HCISectionCard(title: tr("动画与视觉效果", "Animation & Effects"), icon: "slider.horizontal.3") {
            VStack(spacing: 12) {
                // Follow Speed
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tr("跟随灵敏度", "Follow Speed"))
                            .font(.subheadline)
                        
                        InfoButton(tr("跟随速度", "Follow Speed"), content: tr("画面追上屏幕实际角度的速度。数值越大越跟手，越小越顺滑，但会稍有延迟。", "How quickly the fold catches up with the lid. Higher values follow more tightly; lower values are smoother but lag slightly."))
                        
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
                            Text(tr("模糊强度", "Blur"))
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
                            Text(tr("玻璃反射", "Glass Reflection"))
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
        HCISectionCard(title: tr("锁屏与睡眠唤醒", "Lock Screen & Wake"), icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("锁屏开盖动画", "Lock Screen Animation"))
                            .font(.subheadline)
                        Text(settings.lockScreenStatus.text)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(tr("锁定期间持续跟随开合角度，可反复合盖、开盖，无时间限制。", "Follows the lid angle while locked, however often you close and open it, with no time limit."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    InfoButton(tr("锁屏唤醒", "Lock Screen Wake"), content: tr("通过系统锁屏显示空间呈现开盖动画。锁定期间使用壁纸，不显示桌面快照；动画不接收键盘和鼠标输入。此功能使用私有接口，需要关闭 SIP，系统更新后可能需要适配。", "Shows the lid-open animation in the system lock screen display space. While locked it uses the wallpaper instead of a desktop snapshot, and the animation never receives keyboard or mouse input. It uses private interfaces, requires SIP to be disabled, and may need updates after macOS changes."))
                    
                    Spacer()
                    
                    Toggle("", isOn: $settings.enableLockScreenPriority)
                        .labelsHidden()
                        .disabled(LockScreenSpace.isSIPEnabled)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("配套屏幕保护程序（.saver）", "Companion Screen Saver (.saver)"))
                                .font(.subheadline)
                            Text(isScreenSaverInstalled ? tr("已安装至 ~/Library/Screen Savers/macTilt.saver", "Installed at ~/Library/Screen Savers/macTilt.saver") : tr("直接在 macOS 密码锁定屏幕上呈现合盖折叠动画。", "Shows the fold animation directly on the macOS password lock screen."))
                                .font(.caption)
                                .foregroundStyle(isScreenSaverInstalled ? Color.green : Color.secondary)
                        }
                        
                        InfoButton(tr("锁屏配套组件", "Lock Screen Companion"), content: tr("Apple 允许屏幕保护程序直接在密码锁定屏幕上渲染。安装此组件后，macTilt 可向锁屏实时传递开合角度，闲置时不增加耗电。", "Apple lets screen savers draw directly on the password lock screen. With this component installed, macTilt passes the lid angle to the lock screen in real time, with no extra power use when idle."))
                        
                        Spacer()
                    }
                    
                    HStack(spacing: 8) {
                        Button(isScreenSaverInstalled ? tr("重新安装组件", "Reinstall Component") : tr("安装配套组件（.saver）", "Install Companion (.saver)")) {
                            installScreenSaver()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        if isScreenSaverInstalled {
                            Button(tr("测试屏幕保护程序", "Test Screen Saver")) {
                                testScreenSaver()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button(tr("打开设置", "Open Settings")) {
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
        HCISectionCard(title: tr("交互预览", "Interactive Preview"), icon: "play.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(tr("预览动画", "Preview Animation"))
                        .font(.subheadline)
                    
                    InfoButton(tr("交互预览", "Interactive Preview"), content: tr("拖动滑块即可在屏幕上预览折叠效果，无需实际开合屏幕。", "Drag the slider to preview the fold on screen without moving the lid."))
                    
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
                            Text(tr("折叠进度", "Fold Progress"))
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
            Button(tr("恢复默认设置", "Restore Defaults")) {
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
            
            Button(tr("使用指南", "Guide")) {
                MenuBarController.shared.openOnboardingWindow()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            Spacer()
            
            Button(tr("完成", "Done")) {
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
        panel.title = tr("选择自定义图片", "Choose a Custom Image")
        panel.message = tr("请选择用于合盖动画的图片。", "Choose an image for the lid animation.")
        panel.prompt = tr("选择", "Choose")
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
