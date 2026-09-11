import Foundation
import AppKit
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
    private var stationaryFrames: Int = 0
    
    private init() {
        setupManager()
        setupWakeObservers()
    }
    
    deinit {
        stop()
    }
    
    private func setupWakeObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
    }
    
    public func handleWake() {
        if isDeviceOpen, let device = hidDevice {
            IOHIDDeviceClose(device, Self.noOptions)
            isDeviceOpen = false
        }
        if let manager = hidManager { IOHIDManagerClose(manager, Self.noOptions) }
        hidDevice = nil
        hidManager = nil
        lastTime = nil
        hasPreArmedInThisMotion = false
        setupManager()
        if let device = hidDevice {
            if IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess {
                isDeviceOpen = true
            }
        }
    }
    
    private func setupManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess else {
            AppSettings.shared.sensorStatus = .managerUnavailable
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
            AppSettings.shared.sensorStatus = .connected
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
                        AppSettings.shared.sensorStatus = .connected
                        break
                    }
                }
            }
        }
        
        if self.hidDevice == nil {
            AppSettings.shared.isSensorConnected = false
            AppSettings.shared.sensorStatus = .notFound
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
                let isMovingUpward = delta > 0.6
                
                if isMovingDownward {
                    isActivelyClosing = true
                    stationaryFrames = 0
                } else if isMovingUpward {
                    isActivelyClosing = false
                    hasPreArmedInThisMotion = false
                    stationaryFrames = 0
                } else {
                    stationaryFrames += 1
                    if stationaryFrames > 12 { // ~200ms of no downward movement
                        isActivelyClosing = false
                    }
                }
                
                // If lid is safely open, reset pre-arm latch and mark capture engine dormant
                if angle >= settings.startTiltAngle || (!isActivelyClosing && angle >= settings.startTiltAngle - 10.0) {
                    hasPreArmedInThisMotion = false
                    settings.isScreenCaptureDormant = true
                }
                
                // Hardware Pre-Arming Capture Zone:
                // Pre-arms right as lid enters folding range
                let nowTime = CACurrentMediaTime()
                let preArmThreshold = min(135.0, settings.startTiltAngle + 15.0)
                if angle <= preArmThreshold && angle < settings.startTiltAngle {
                    if !hasPreArmedInThisMotion && (nowTime - lastPreArmTime > 2.0) {
                        hasPreArmedInThisMotion = true
                        lastPreArmTime = nowTime
                        settings.isScreenCaptureDormant = false
                        onPreArmCapture?()
                    }
                }
                
                previousRawAngle = angle
                currentRawAngle = angle
                settings.currentLidAngle = angle
                settings.isClosing = isActivelyClosing
                settings.isSensorConnected = true
            } else {
                // Device connection may have dropped or suspended during deep sleep
                isDeviceOpen = false
                if IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess {
                    isDeviceOpen = true
                }
            }
        }
        
        // Compute target turn: continuously mirrors physical angle across full range
        targetTurn = settings.normalizedTurn(for: currentRawAngle)
        
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
