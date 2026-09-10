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
    private let kHasCompletedOnboarding = "mactilt_hasCompletedOnboarding"
    
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
    
    // MARK: - Real-time State
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
    @Published public var sensorStatusMessage: String = "Initializing sensor..."
    @Published public var hasScreenRecordingPermission: Bool = false
    @Published public var lastCaptureDate: Date? = nil
    @Published public var isScreenCaptureDormant: Bool = true
    
    private init() {
        let defaults = UserDefaults.standard
        
        // Defaults matching User Preferences
        self.hasCompletedOnboarding = defaults.bool(forKey: kHasCompletedOnboarding)
        self.startTiltAngle = defaults.object(forKey: kStartTiltAngle) != nil ? defaults.double(forKey: kStartTiltAngle) : 115.0
        self.endTiltAngle = defaults.object(forKey: kEndTiltAngle) != nil ? defaults.double(forKey: kEndTiltAngle) : 3.0
        self.followSpeed = defaults.object(forKey: kFollowSpeed) != nil ? defaults.double(forKey: kFollowSpeed) : 16.0
        
        let savedSource = defaults.integer(forKey: kImageSourceMode)
        self.imageSourceMode = defaults.object(forKey: kImageSourceMode) != nil ? (ImageSourceMode(rawValue: savedSource) ?? .liveCapture) : .liveCapture
        
        self.customImagePath = defaults.string(forKey: kCustomImagePath) ?? ""
        self.blurStrength = defaults.object(forKey: kBlurStrength) != nil ? defaults.double(forKey: kBlurStrength) : 0.5
        self.reflectionIntensity = defaults.object(forKey: kReflectionIntensity) != nil ? defaults.double(forKey: kReflectionIntensity) : 0.0
        
        self.showAngleInMenuBar = defaults.object(forKey: kShowAngleInMenuBar) != nil ? defaults.bool(forKey: kShowAngleInMenuBar) : true
        
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
    
    /// Calculate normalized turn (0.0 to 1.0) across the entire closing motion
    public func normalizedTurn(for angle: Double, isLidClosing: Bool) -> Double {
        if isTestModeActive {
            return min(1.0, max(0.0, testTurnValue))
        }
        
        // User is using MacBook normally: do nothing
        if angle >= startTiltAngle {
            return 0.0
        }
        
        // If opening or not closing: do nothing
        if !isLidClosing {
            return 0.0
        }
        
        if angle <= endTiltAngle {
            return 1.0
        }
        
        let range = startTiltAngle - endTiltAngle
        guard range > 0.001 else { return 0.0 }
        
        let rawProgress = (startTiltAngle - angle) / range
        return min(1.0, max(0.0, rawProgress))
    }
}
