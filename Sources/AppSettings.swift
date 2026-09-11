import Foundation
import Combine
import SwiftUI

public enum ImageSourceMode: Int, CaseIterable, Identifiable {
    case liveCapture = 0
    case desktopWallpaper = 1
    case bundledArtwork = 2
    case customImage = 3
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .liveCapture: return tr("实时屏幕捕获", "Live Screen Capture")
        case .desktopWallpaper: return tr("桌面壁纸", "Desktop Wallpaper")
        case .bundledArtwork: return tr("内置图片", "Bundled Artwork")
        case .customImage: return tr("自定义图片", "Custom Image")
        }
    }
}

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return tr("跟随系统", "System")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

/// Returns the Simplified Chinese or English copy for the current interface language.
public func tr(_ chinese: String, _ english: String) -> String {
    AppSettings.shared.usesChinese ? chinese : english
}

public enum LockScreenStatus {
    case initializing, needsSIPDisabled, configured, unavailable

    public var text: String {
        switch self {
        case .initializing: return tr("正在初始化锁屏显示接口…", "Setting up the lock screen display…")
        case .needsSIPDisabled: return tr("需要先关闭系统完整性保护（SIP）", "Requires System Integrity Protection (SIP) to be disabled")
        case .configured: return tr("已配置锁屏接口（待实际开盖验证）", "Lock screen display configured (confirm by opening the lid)")
        case .unavailable: return tr("锁屏显示接口不可用", "Lock screen display unavailable")
        }
    }
}

public enum SensorStatus {
    case initializing, managerUnavailable, connected, notFound

    public var text: String {
        switch self {
        case .initializing: return tr("正在初始化传感器…", "Initializing sensor…")
        case .managerUnavailable: return tr("无法初始化 IOHIDManager。", "Could not initialize IOHIDManager.")
        case .connected: return tr("屏幕开合角度传感器已连接。", "Lid angle sensor connected.")
        case .notFound: return tr("未在此 Mac 上检测到屏幕开合角度传感器。", "No lid angle sensor found on this Mac.")
        }
    }
}

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    
    // MARK: - Persistent User Defaults Keys
    private let kStartTiltAngle = "mactilt_startTiltAngle"
    private let kEndTiltAngle = "mactilt_endTiltAngle"
    private let kFollowSpeed = "mactilt_followSpeed"
    private let kImageSourceMode = "mactilt_imageSourceMode"
    private let kCustomImagePath = "mactilt_customImagePath"
    private let kBlurStrength = "mactilt_blurStrength"
    private let kReflectionIntensity = "mactilt_reflectionIntensity"
    private let kShowAngleInMenuBar = "mactilt_showAngleInMenuBar"
    private let kEnableLockScreenPriority = "mactilt_enable_lock_screen_priority"
    private let kHasCompletedOnboarding = "mactilt_hasCompletedOnboarding"
    private let kLanguage = "mactilt_language"
    
    // MARK: - Customizable Animation Options
    @Published public var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: kHasCompletedOnboarding) }
    }
    
    @Published public var startTiltAngle: Double {
        didSet { UserDefaults.standard.set(startTiltAngle, forKey: kStartTiltAngle) }
    }
    
    @Published public var endTiltAngle: Double {
        didSet { UserDefaults.standard.set(endTiltAngle, forKey: kEndTiltAngle) }
    }
    
    @Published public var followSpeed: Double {
        didSet { UserDefaults.standard.set(followSpeed, forKey: kFollowSpeed) }
    }
    
    @Published public var imageSourceMode: ImageSourceMode {
        didSet { UserDefaults.standard.set(imageSourceMode.rawValue, forKey: kImageSourceMode) }
    }
    
    @Published public var customImagePath: String {
        didSet { UserDefaults.standard.set(customImagePath, forKey: kCustomImagePath) }
    }
    
    @Published public var blurStrength: Double {
        didSet { UserDefaults.standard.set(blurStrength, forKey: kBlurStrength) }
    }
    
    @Published public var reflectionIntensity: Double {
        didSet { UserDefaults.standard.set(reflectionIntensity, forKey: kReflectionIntensity) }
    }
    
    @Published public var showAngleInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showAngleInMenuBar, forKey: kShowAngleInMenuBar)
            MenuBarController.shared.refreshMenuBarTitle()
        }
    }
    
    @Published public var enableLockScreenPriority: Bool {
        didSet {
            UserDefaults.standard.set(enableLockScreenPriority, forKey: kEnableLockScreenPriority)
            OverlayWindowController.shared.updateWindowLevel()
        }
    }

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: kLanguage)
            MenuBarController.shared.refreshLocalizedText()
        }
    }

    /// Whether the interface is shown in Simplified Chinese.
    public var usesChinese: Bool {
        switch language {
        case .chinese: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }
    
    // MARK: - Real-time State
    @Published public var lockScreenStatus: LockScreenStatus = .initializing
    @Published public var isTestModeActive: Bool = false {
        didSet {
            if !isTestModeActive {
                testTurnValue = 0.0
            }
        }
    }
    @Published public var testTurnValue: Double = 0.0
    @Published public var currentLidAngle: Double = 120.0
    @Published public var isSensorConnected: Bool = false
    @Published public var isClosing: Bool = false
    @Published public var sensorStatus: SensorStatus = .initializing
    @Published public var hasScreenRecordingPermission: Bool = false
    @Published public var lastCaptureDate: Date? = nil
    @Published public var isScreenCaptureDormant: Bool = true
    
    private init() {
        let defaults = UserDefaults.standard
        
        // Defaults matching User Preferences
        self.hasCompletedOnboarding = defaults.bool(forKey: kHasCompletedOnboarding)
        self.language = AppLanguage(rawValue: defaults.string(forKey: kLanguage) ?? "") ?? .system
        self.startTiltAngle = defaults.object(forKey: kStartTiltAngle) != nil ? defaults.double(forKey: kStartTiltAngle) : 115.0
        self.endTiltAngle = defaults.object(forKey: kEndTiltAngle) != nil ? defaults.double(forKey: kEndTiltAngle) : 3.0
        self.followSpeed = defaults.object(forKey: kFollowSpeed) != nil ? defaults.double(forKey: kFollowSpeed) : 16.0
        
        let savedSource = defaults.integer(forKey: kImageSourceMode)
        self.imageSourceMode = defaults.object(forKey: kImageSourceMode) != nil ? (ImageSourceMode(rawValue: savedSource) ?? .liveCapture) : .liveCapture
        
        self.customImagePath = defaults.string(forKey: kCustomImagePath) ?? ""
        self.blurStrength = defaults.object(forKey: kBlurStrength) != nil ? defaults.double(forKey: kBlurStrength) : 0.5
        self.reflectionIntensity = defaults.object(forKey: kReflectionIntensity) != nil ? defaults.double(forKey: kReflectionIntensity) : 0.0
        
        self.showAngleInMenuBar = defaults.object(forKey: kShowAngleInMenuBar) != nil ? defaults.bool(forKey: kShowAngleInMenuBar) : true
        // The lock-screen space needs SIP off; the saved choice comes back once it is.
        self.enableLockScreenPriority = !LockScreenSpace.isSIPEnabled
            && (defaults.object(forKey: kEnableLockScreenPriority) != nil ? defaults.bool(forKey: kEnableLockScreenPriority) : true)
        
        // Listen for app becoming active to re-check permissions immediately
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPermissions()
        }
        
        refreshPermissions()
    }
    
    public func refreshPermissions() {
        // Fast synchronous check
        let syncStatus = ScreenCapture.shared.hasPermission()
        self.hasScreenRecordingPermission = syncStatus
        
        // Asynchronous active probe via ScreenCaptureKit
        Task {
            let verified = await ScreenCapture.shared.verifyPermissionAsync()
            await MainActor.run {
                self.hasScreenRecordingPermission = verified
            }
        }
    }
    
    /// Calculate normalized turn (0.0 to 1.0) across the entire folding range (closing, opening, or stopped)
    public func normalizedTurn(for angle: Double) -> Double {
        if isTestModeActive {
            return min(1.0, max(0.0, testTurnValue))
        }
        
        // Lid is open at or beyond start tilt angle: flat / no fold
        if angle >= startTiltAngle {
            return 0.0
        }
        
        // Lid is fully closed at or below end tilt angle: full fold
        if angle <= endTiltAngle {
            return 1.0
        }
        
        let range = startTiltAngle - endTiltAngle
        guard range > 0.001 else { return 0.0 }
        
        let rawProgress = (startTiltAngle - angle) / range
        return min(1.0, max(0.0, rawProgress))
    }
}
