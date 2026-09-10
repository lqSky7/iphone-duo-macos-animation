import Foundation
import IOKit.hid
import QuartzCore

public final class LidSensor {
    public static let shared = LidSensor()
    
    public typealias TurnCallback = (_ turn: Double, _ angle: Double) -> Void
    public var onTurnUpdate: TurnCallback?
    public var onPreArmCapture: (() -> Void)?
    
    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private var isDeviceOpen = false
    private var timer: Timer?
    
    private var hidReport = [UInt8](repeating: 0, count: 8)
    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    
    // Physics and motion tracking
    private var lastTime: CFTimeInterval?
    public private(set) var displayTurn: Double = 0.0
    public private(set) var targetTurn: Double = 0.0
    public private(set) var currentRawAngle: Double = 120.0
    private var previousRawAngle: Double = 120.0
    private var isActivelyClosing: Bool = false
    private var hasPreArmedInThisMotion: Bool = false
    private var lastPreArmTime: CFTimeInterval = 0
    
    private init() {
        setupManager()
    }
    
    deinit {
        stop()
    }
    
    private func setupManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess else {
            AppSettings.shared.sensorStatusMessage = "Failed to initialize IOHIDManager."
            AppSettings.shared.isSensorConnected = false
            return
        }
        self.hidManager = manager
        
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            kIOHIDDeviceUsagePageKey as String: 0x0020,
            kIOHIDDeviceUsageKey as String: 0x008A
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first {
            self.hidDevice = device
            AppSettings.shared.isSensorConnected = true
            AppSettings.shared.sensorStatusMessage = "Lid Angle Sensor connected."
        } else {
            // Fallback: search across all 0x8104 devices for page 32 usage 138
            let fallbackMatching: [String: Any] = [
                kIOHIDVendorIDKey as String: 0x05AC,
                kIOHIDProductIDKey as String: 0x8104
            ]
            IOHIDManagerSetDeviceMatching(manager, fallbackMatching as CFDictionary)
            if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
                for dev in devices {
                    let page = (IOHIDDeviceGetProperty(dev, "PrimaryUsagePage" as CFString) as? Int) ?? 0
                    let usage = (IOHIDDeviceGetProperty(dev, "PrimaryUsage" as CFString) as? Int) ?? 0
                    if page == 32 && usage == 138 {
                        self.hidDevice = dev
                        AppSettings.shared.isSensorConnected = true
                        AppSettings.shared.sensorStatusMessage = "Lid Angle Sensor connected."
                        break
                    }
                }
            }
        }
        
        if self.hidDevice == nil {
            AppSettings.shared.isSensorConnected = false
            AppSettings.shared.sensorStatusMessage = "No Lid Angle Sensor detected on this Mac."
        }
    }
    
    public func start() {
        guard timer == nil else { return }
        
        if let device = hidDevice, !isDeviceOpen {
            if IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess {
                isDeviceOpen = true
            }
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    public func stop() {
        timer?.invalidate()
        timer = nil
        if isDeviceOpen, let device = hidDevice {
            IOHIDDeviceClose(device, Self.noOptions)
            isDeviceOpen = false
        }
    }
    
    private func tick() {
        let settings = AppSettings.shared
        
        if isDeviceOpen, let device = hidDevice {
            var length = CFIndex(hidReport.count)
            let result = IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                1,
                &hidReport,
                &length
            )
            if result == kIOReturnSuccess, length >= 3 {
                let rawValue = UInt16(hidReport[2]) << 8 | UInt16(hidReport[1])
                let angle = Double(rawValue)
                
                // Track direction of movement and velocity
                let delta = angle - previousRawAngle
                let isMovingDownward = delta < -0.4
                let isMovingUpward = delta > 0.8
                
                if isMovingDownward {
                    isActivelyClosing = true
                } else if isMovingUpward {
                    isActivelyClosing = false
                    hasPreArmedInThisMotion = false
                }
                
                // If lid is safely open, reset pre-arm latch and mark capture engine dormant
                if angle > (settings.startTiltAngle + 5.0) {
                    hasPreArmedInThisMotion = false
                    settings.isScreenCaptureDormant = true
                    if !isMovingDownward {
                        isActivelyClosing = false
                    }
                }
                
                // Hardware Pre-Arming Capture Zone:
                // Triggers asynchronously during closing motion (e.g. 80° - 100°)
                // Gives ScreenCaptureKit 150-250ms to grab texture before fold begins at startTiltAngle
                let nowTime = CACurrentMediaTime()
                let preArmThreshold = settings.startTiltAngle + 20.0
                if angle <= preArmThreshold && angle >= (settings.startTiltAngle - 2.0) {
                    if isActivelyClosing && !hasPreArmedInThisMotion && (nowTime - lastPreArmTime > 2.5) {
                        hasPreArmedInThisMotion = true
                        lastPreArmTime = nowTime
                        settings.isScreenCaptureDormant = false
                        onPreArmCapture?()
                    }
                }
                
                // Safety fallback for ultra-fast slams crossing startTiltAngle directly
                if angle < settings.startTiltAngle && isActivelyClosing && !hasPreArmedInThisMotion && (nowTime - lastPreArmTime > 2.5) {
                    hasPreArmedInThisMotion = true
                    lastPreArmTime = nowTime
                    settings.isScreenCaptureDormant = false
                    onPreArmCapture?()
                }
                
                previousRawAngle = angle
                currentRawAngle = angle
                settings.currentLidAngle = angle
                settings.isClosing = isActivelyClosing
                settings.isSensorConnected = true
            }
        }
        
        // Compute target turn: only when closing and below startTiltAngle
        targetTurn = settings.normalizedTurn(for: currentRawAngle, isLidClosing: isActivelyClosing)
        
        // Follow easing physics
        let now = CACurrentMediaTime()
        let dt: Double
        if let last = lastTime {
            dt = min(now - last, 0.1)
        } else {
            dt = 1.0 / 60.0
        }
        lastTime = now
        
        let follow = settings.followSpeed
        let factor = 1.0 - exp(-dt * follow)
        displayTurn += (targetTurn - displayTurn) * factor
        if abs(targetTurn - displayTurn) < 0.0005 {
            displayTurn = targetTurn
        }
        
        onTurnUpdate?(displayTurn, currentRawAngle)
    }
}
