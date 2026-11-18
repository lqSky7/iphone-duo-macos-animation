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
        case .liveCapture: return "Live Screen Capture"
        case .desktopWallpaper: return "Desktop Wallpaper"
        case .bundledArtwork: return "Bundled Artwork"
        case .customImage: return "Custom Image"
        }
    }
}

/// Live lid angle for the settings badge alone (see AppSettings.currentLidAngle).
public final class LiveLidAngle: ObservableObject {
    public static let shared = LiveLidAngle()
    @Published public var angle: Double = 120.0
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
    private let kSideVoidAmount = "mactilt_sideVoidAmount"
    private let kShowAngleInMenuBar = "mactilt_showAngleInMenuBar"
    private let kEnableLockScreenPriority = "mactilt_enable_lock_screen_priority"
    private let kHasCompletedOnboarding = "mactilt_hasCompletedOnboarding"
    private let kAutomaticallyCheckForUpdates = "mactilt_automaticallyCheckForUpdates"
    private let kHideMenuBarIcon = "mactilt_hideMenuBarIcon"
    private let kDuoMode = "mactilt_duoMode"
    private let kClamshellOpeningDuration = "mactilt_clamshellOpeningDuration"
    private let kAutoReleaseFold = "mactilt_autoReleaseFold"
    private let kAutoReleaseDelay = "mactilt_autoReleaseDelay"

    /// Public so LidSensor can read the stored default off the main thread.
    public static let kProbeLidAngleSensor = "mactilt_probeLidAngleSensor"

    /// Off-main-safe read of the probe switch. LidSensor decides whether to open
    /// a HID device on its own queue, where reaching through a @Published getter
    /// would not be sound, so it reads the stored default directly.
    public static var isLidAngleSensorProbeEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: kProbeLidAngleSensor) != nil
            ? defaults.bool(forKey: kProbeLidAngleSensor)
            : true
    }

    /// Whether macTilt may look for Apple's lid angle sensor at all. Off means no
    /// HID device is ever opened: the app runs on the clamshell switch and the
    /// opening animation, which is a complete experience on Macs that never had
    /// the sensor, and an escape hatch on Macs that do.
    @Published public var probeLidAngleSensor: Bool {
        didSet {
            UserDefaults.standard.set(probeLidAngleSensor, forKey: Self.kProbeLidAngleSensor)
            LidSensor.shared.reprobeHardware()
        }
    }
    
    // MARK: - Customizable Animation Options
    @Published public var clamshellOpeningDuration: Double {
        didSet {
            let clamped = min(max(clamshellOpeningDuration, 0.4), 2.5)
            if clamped != clamshellOpeningDuration {
                clamshellOpeningDuration = clamped
                return
            }
            UserDefaults.standard.set(clamshellOpeningDuration, forKey: kClamshellOpeningDuration)
        }
    }
    
    @Published public var automaticallyCheckForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyCheckForUpdates, forKey: kAutomaticallyCheckForUpdates) }
    }

    /// Unwind the fold once the lid stops moving (issue #9). A lid parked at a
    /// partial angle is a screen someone is using, not a fold in progress —
    /// and the angles people actually work at sit *below* the start-fold
    /// threshold, so resting is the common case, not an edge case. Without
    /// this, resting the lid leaves the desktop folded and blurred for as long
    /// as you stay there.
    @Published public var autoReleaseFold: Bool {
        didSet { UserDefaults.standard.set(autoReleaseFold, forKey: kAutoReleaseFold) }
    }

    /// How long the lid has to stay still before the fold unwinds, in seconds.
    @Published public var autoReleaseDelay: Double {
        didSet {
            let clamped = min(max(autoReleaseDelay, 0.3), 3.0)
            if clamped != autoReleaseDelay {
                // Assigning inside didSet does not re-enter it, so persist the
                // clamped value here rather than leaving the store on the old
                // one.
                autoReleaseDelay = clamped
                UserDefaults.standard.set(clamped, forKey: kAutoReleaseDelay)
                return
            }
            UserDefaults.standard.set(autoReleaseDelay, forKey: kAutoReleaseDelay)
        }
    }
    
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
    
    /// How much black creeps in from the left and right edges as the panel
    /// folds — the horizontal parallax spread of the projected plane.
    /// 0.0 = the frozen frame keeps its full width, 1.0 = the physical
    /// projection (default), up to 2.0 = exaggerated falloff.
    @Published public var sideVoidAmount: Double {
        didSet {
            let clamped = min(max(sideVoidAmount, 0.0), 2.0)
            if clamped != sideVoidAmount {
                sideVoidAmount = clamped
                return
            }
            UserDefaults.standard.set(sideVoidAmount, forKey: kSideVoidAmount)
        }
    }
    
    @Published public var showAngleInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showAngleInMenuBar, forKey: kShowAngleInMenuBar)
            MenuBarController.shared.refreshMenuBarTitle()
        }
    }
    
    /// Hides the status bar icon entirely. Settings stay reachable by
    /// relaunching macTilt from Finder, which reopens the panel.
    /// Duo Mode: the picture looks like it stays upright while the lid
    /// closes. Off = the original macTilt fold.
    @Published public var duoMode: Bool {
        didSet { UserDefaults.standard.set(duoMode, forKey: kDuoMode) }
    }

    @Published public var hideMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideMenuBarIcon, forKey: kHideMenuBarIcon)
            MenuBarController.shared.applyMenuBarIconVisibility()
        }
    }
    
    @Published public var enableLockScreenPriority: Bool {
        didSet {
            UserDefaults.standard.set(enableLockScreenPriority, forKey: kEnableLockScreenPriority)
            OverlayWindowController.shared.updateWindowLevel()
        }
    }
    
    // MARK: - Real-time State
    @Published public var isTestModeActive: Bool = false {
        didSet {
            if !isTestModeActive {
                testTurnValue = 0.0
            }
        }
    }
    @Published public var testTurnValue: Double = 0.0
    /// Not @Published: a moving lid would re-evaluate the whole settings panel ~10×/s.
    /// Only the angle badge observes it, through LiveLidAngle.
    public var currentLidAngle: Double = 120.0 {
        didSet {
            if Int(currentLidAngle) != Int(oldValue) { LiveLidAngle.shared.angle = currentLidAngle }
        }
    }
    @Published public var isSensorConnected: Bool = false
    @Published public var isHardwareSensor: Bool = false
    @Published public var isClamshellMode: Bool = false
    @Published public var isClosing: Bool = false
    @Published public var sensorStatusMessage: String = "Initializing sensor..."
    @Published public var hasScreenRecordingPermission: Bool = false
    @Published public var lastCaptureDate: Date? = nil
    @Published public var isScreenCaptureDormant: Bool = true

    private var appActiveObserver: NSObjectProtocol?
    
    private init() {
        let defaults = UserDefaults.standard
        
        // Defaults matching User Preferences
        self.hasCompletedOnboarding = defaults.bool(forKey: kHasCompletedOnboarding)
        self.probeLidAngleSensor = Self.isLidAngleSensorProbeEnabled
        self.startTiltAngle = defaults.object(forKey: kStartTiltAngle) != nil ? defaults.double(forKey: kStartTiltAngle) : 115.0
        self.endTiltAngle = defaults.object(forKey: kEndTiltAngle) != nil ? defaults.double(forKey: kEndTiltAngle) : 3.0
        self.followSpeed = defaults.object(forKey: kFollowSpeed) != nil ? defaults.double(forKey: kFollowSpeed) : 16.0
        
        let savedSource = defaults.integer(forKey: kImageSourceMode)
        self.imageSourceMode = defaults.object(forKey: kImageSourceMode) != nil ? (ImageSourceMode(rawValue: savedSource) ?? .liveCapture) : .liveCapture
        
        self.customImagePath = defaults.string(forKey: kCustomImagePath) ?? ""
        self.blurStrength = defaults.object(forKey: kBlurStrength) != nil ? defaults.double(forKey: kBlurStrength) : 0.5
        self.reflectionIntensity = defaults.object(forKey: kReflectionIntensity) != nil ? defaults.double(forKey: kReflectionIntensity) : 0.0
        self.sideVoidAmount = defaults.object(forKey: kSideVoidAmount) != nil ? defaults.double(forKey: kSideVoidAmount) : 1.0
        
        self.showAngleInMenuBar = defaults.object(forKey: kShowAngleInMenuBar) != nil ? defaults.bool(forKey: kShowAngleInMenuBar) : true
        self.duoMode = defaults.object(forKey: kDuoMode) != nil ? defaults.bool(forKey: kDuoMode) : true
        self.hideMenuBarIcon = defaults.object(forKey: kHideMenuBarIcon) != nil ? defaults.bool(forKey: kHideMenuBarIcon) : false
        self.enableLockScreenPriority = defaults.object(forKey: kEnableLockScreenPriority) != nil ? defaults.bool(forKey: kEnableLockScreenPriority) : true
        self.automaticallyCheckForUpdates = defaults.object(forKey: kAutomaticallyCheckForUpdates) != nil ? defaults.bool(forKey: kAutomaticallyCheckForUpdates) : true
        self.clamshellOpeningDuration = defaults.object(forKey: kClamshellOpeningDuration) != nil ? defaults.double(forKey: kClamshellOpeningDuration) : 0.95
        self.autoReleaseFold = defaults.object(forKey: kAutoReleaseFold) != nil ? defaults.bool(forKey: kAutoReleaseFold) : true
        self.autoReleaseDelay = defaults.object(forKey: kAutoReleaseDelay) != nil ? defaults.double(forKey: kAutoReleaseDelay) : 1.0
        
        // Listen for app becoming active to re-check permissions immediately
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPermissions()
        }
        
        refreshPermissions()
    }

    deinit {
        if let token = appActiveObserver {
            NotificationCenter.default.removeObserver(token)
        }
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
