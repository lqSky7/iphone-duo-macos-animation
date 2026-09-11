import SwiftUI
import AppKit

public struct OnboardingView: View {
    @ObservedObject var settings: AppSettings = AppSettings.shared
    public var onDismiss: (() -> Void)?
    
    public init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                appIconView
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                
                VStack(spacing: 4) {
                    Text(tr("欢迎使用 macTilt", "Welcome to macTilt"))
                        .font(.system(size: 26, weight: .bold))
                    
                    Text(tr("为 MacBook 屏幕带来逼真的 3D 合盖折叠动画。", "A lifelike 3D fold animation for your MacBook display as the lid closes."))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 32)
            .padding(.horizontal, 28)
            
            // Feature Highlights
            VStack(spacing: 16) {
                FeatureRow(
                    icon: "laptopcomputer",
                    iconColor: .blue,
                    title: tr("随合盖动作自然折叠", "Folds With Your Lid"),
                    subtitle: tr("与 Apple 内置屏幕开合角度传感器一比一同步。合盖时，画面停在原来的角度，屏幕像玻璃一样从它前面合上。", "Synced one-to-one with Apple’s built-in lid angle sensor. As the lid closes, the picture stays at its angle while the screen closes in front of it like glass.")
                )
                
                FeatureRow(
                    icon: "battery.100.bolt",
                    iconColor: .green,
                    title: tr("闲置时零额外耗电", "No Extra Power When Idle"),
                    subtitle: tr("正常使用时完全休眠，无后台轮询。仅在实际合盖时准备屏幕捕获。", "Fully asleep during normal use, with no background polling. A screen capture is prepared only when you actually close the lid.")
                )
                
                FeatureRow(
                    icon: "record.circle.fill",
                    iconColor: .orange,
                    title: tr("屏幕录制权限", "Screen Recording Permission"),
                    subtitle: tr("合盖时，将当前桌面定格并呈现为 3D 动画。所有处理均在本机完成，无需联网。", "When the lid closes, your current desktop is frozen and shown as a 3D animation. Everything happens on this Mac, with no network connection.")
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            
            // Permission Action Card
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(settings.hasScreenRecordingPermission ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    
                    Text(settings.hasScreenRecordingPermission ? tr("已获得屏幕录制权限", "Screen Recording permission granted") : tr("需要屏幕录制权限", "Screen Recording permission required"))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    if !settings.hasScreenRecordingPermission {
                        Button(action: {
                            ScreenCapture.shared.requestPermission()
                            ScreenCapture.shared.openSettings()
                        }) {
                            Text(tr("前往授权…", "Grant Access…"))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                
                if !settings.hasScreenRecordingPermission {
                    HStack {
                        Text(tr("在系统设置中授权后，请点击“重新启动”使其生效。", "After allowing access in System Settings, click Relaunch to apply it."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: {
                            ScreenCapture.shared.relaunchApp()
                        }) {
                            Label(tr("重新启动", "Relaunch"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.horizontal, 28)
            
            Spacer()
            
            // Bottom Action
            HStack {
                Spacer()
                Button(action: {
                    settings.hasCompletedOnboarding = true
                    onDismiss?()
                }) {
                    Text(tr("开始使用", "Get Started"))
                        .font(.headline)
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
            .padding(.bottom, 28)
            .padding(.top, 12)
        }
        .frame(width: 520, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    @ViewBuilder
    private var appIconView: some View {
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: iconUrl) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
        } else if let appIcon = NSApplication.shared.applicationIconImage {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "laptopcomputer")
                .resizable()
                .scaledToFit()
                .foregroundColor(.accentColor)
                .padding(16)
                .background(Color.blue.opacity(0.1))
        }
    }
}

// MARK: - Apple HCI Feature Row
private struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            
            Spacer(minLength: 0)
        }
    }
}
