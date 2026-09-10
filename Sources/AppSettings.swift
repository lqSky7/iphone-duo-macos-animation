import Foundation
import Combine
import SwiftUI

public enum HingeMode: Int, CaseIterable, Identifiable {
    case clamshell = 0
    case bookLeft = 1
    case bookRight = 2
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .clamshell: return "Clamshell (MacBook Bottom Hinge)"
        case .bookLeft: return "iPhone Solo Left"
        case .bookRight: return "iPhone Solo Right"
        }
    }
    
    public var shortTitle: String {
        switch self {
        case .clamshell: return "Clamshell"
        case .bookLeft: return "Book Left"
        case .bookRight: return "Book Right"
        }
    }
}

public enum ImageSourceMode: Int, CaseIterable, Identifiable {
    case liveCapture = 0
    case desktopWallpaper = 1
    case soloDefault = 2
    case customImage = 3
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .liveCapture: return "Live Screen Capture"
        case .desktopWallpaper: return "Desktop Wallpaper"
        case .soloDefault: return "Bundled Solo Artwork"
        case .customImage: return "Custom Image"
        }
    }
}

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    
    // MARK: - Persistent User Defaults Keys
    private let kStartTiltAngle = "duo_startTiltAngle"
    private let kEndTiltAngle = "duo_endTiltAngle"
    private let kFollowSpeed = "duo_followSpeed"
    private let kHingeMode = "duo_hingeMode"
    private let kImageSourceMode = "duo_imageSourceMode"
    private let kCustomImagePath = "duo_customImagePath"
    private let kBlurStrength = "duo_blurStrength"
    private let kReflectionIntensity = "duo_reflectionIntensity"
    
    // MARK: - Customizable Animation Options
    @Published public var startTiltAngle: Double {
        didSet { UserDefaults.standard.set(startTiltAngle, forKey: kStartTiltAngle) }
    }
    
    @Published public var endTiltAngle: Double {
        didSet { UserDefaults.standard.set(endTiltAngle, forKey: kEndTiltAngle) }
    }
    
    @Published public var followSpeed: Double {
        didSet { UserDefaults.standard.set(followSpeed, forKey: kFollowSpeed) }
    }
    
    @Published public var hingeMode: HingeMode {
        didSet { UserDefaults.standard.set(hingeMode.rawValue, forKey: kHingeMode) }
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
    
    // MARK: - Real-time State (Not persisted)
    @Published public var isTestModeActive: Bool = false
    @Published public var testTurnValue: Double = 0.0
    @Published public var currentLidAngle: Double = 120.0
    @Published public var isSensorConnected: Bool = false
    @Published public var sensorStatusMessage: String = "Initializing sensor..."
    
    private init() {
        let defaults = UserDefaults.standard
        
        // Defaults
        self.startTiltAngle = defaults.object(forKey: kStartTiltAngle) != nil ? defaults.double(forKey: kStartTiltAngle) : 110.0
        self.endTiltAngle = defaults.object(forKey: kEndTiltAngle) != nil ? defaults.double(forKey: kEndTiltAngle) : 15.0
        self.followSpeed = defaults.object(forKey: kFollowSpeed) != nil ? defaults.double(forKey: kFollowSpeed) : 16.0
        
        let savedHinge = defaults.integer(forKey: kHingeMode)
        self.hingeMode = HingeMode(rawValue: savedHinge) ?? .clamshell
        
        let savedSource = defaults.integer(forKey: kImageSourceMode)
        self.imageSourceMode = ImageSourceMode(rawValue: savedSource) ?? .liveCapture
        
        self.customImagePath = defaults.string(forKey: kCustomImagePath) ?? ""
        self.blurStrength = defaults.object(forKey: kBlurStrength) != nil ? defaults.double(forKey: kBlurStrength) : 1.0
        self.reflectionIntensity = defaults.object(forKey: kReflectionIntensity) != nil ? defaults.double(forKey: kReflectionIntensity) : 1.0
    }
    
    /// Calculate normalized turn (0.0 to 1.0) given a raw lid angle
    public func normalizedTurn(for angle: Double) -> Double {
        if isTestModeActive {
            return min(1.0, max(0.0, testTurnValue))
        }
        
        // When lid is open wider than startTiltAngle, turn is 0.0 (unfolded/normal)
        if angle >= startTiltAngle {
            return 0.0
        }
        
        // When lid is closed below endTiltAngle, turn is 1.0 (fully folded into dark)
        if angle <= endTiltAngle {
            return 1.0
        }
        
        // Linear interpolation between start and end
        let range = startTiltAngle - endTiltAngle
        guard range > 0.001 else { return 0.0 }
        let progress = (startTiltAngle - angle) / range
        return min(1.0, max(0.0, progress))
    }
}
