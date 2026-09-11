import Foundation
import AppKit
import IOKit
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
    
    // Clamshell mode animation state (MacBook Neo, M1, etc.)
    private var isSimulating: Bool = false
    private var simulationStartTime: CFTimeInterval = 0
    private var simulationDuration: CFTimeInterval = 0.55
    private var simulationStartTurn: Double = 0.0
    private var simulationTargetTurn: Double = 0.0
    private var simulationStartAngle: Double = 120.0
    private var simulationTargetAngle: Double = 35.0
    private var lastKnownClamshellClosed: Bool = false
    
    private init() {
        setupManager()
        setupWakeAndSleepObservers()
    }
    
    deinit {
        stop()
    }
    
    private func setupWakeAndSleepObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        }
    }
    
    public func handleWake() {
        if AppSettings.shared.isHardwareSensor {
            if isDeviceOpen, let device = hidDevice {
                IOHIDDeviceClose(device, Self.noOptions)
                isDeviceOpen = false
            }
            setupManager()
            if let device = hidDevice {
                if IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess {
                    isDeviceOpen = true
                }
            }
        } else {
            // Clamshell mode: on wake / opening from sleep, animate unfold
            animateUnfold()
        }
    }
    
    public func handleWillSleep() {
        if !AppSettings.shared.isHardwareSensor {
            // Clamshell mode: animate fold on sleep
            animateFold()
        }
    }
    
    private func setupManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess else {
            activateClamshellMode(reason: "IOHIDManager unavailable")
            return
        }
        self.hidManager = manager
        
        // Multi-Strategy Hardware Sensor Probing:
        // STRICTLY match only sensor hardware (UsagePage 0x20, PID 0x8104, "las").
        // NEVER match keyboards or general input to prevent macOS from asking for "Keystroke Receiving" permission.
        let matchingCriteria: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: 0x05AC,
                kIOHIDProductIDKey as String: 0x8104
            ],
            [
                kIOHIDPrimaryUsagePageKey as String: 0x0020,
                kIOHIDPrimaryUsageKey as String: 0x008A
            ],
            [
                kIOHIDDeviceUsagePageKey as String: 0x0020,
                kIOHIDDeviceUsageKey as String: 0x008A
            ],
            [
                kIOHIDProductKey as String: "las"
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingCriteria as CFArray)
        
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            activateClamshellMode(reason: "No sensor HID devices found")
            return
        }
        
        var foundDevice: IOHIDDevice?
        var detectedPid: Int = 0
        var detectedProd: String = ""
        
        for dev in devices {
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
            let usage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
            
            // Hard safety guard: Skip any keyboard, mouse, or pointer devices
            if page == 1 { continue }
            
            let prod = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? ""
            let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            
            let isCandidate = prod.lowercased() == "las" ||
                              prod.lowercased().contains("lid") ||
                              prod.lowercased().contains("angle") ||
                              (page == 32 && usage == 138) ||
                              pid == 0x8104
            
            if isCandidate {
                if IOHIDDeviceOpen(dev, Self.noOptions) == kIOReturnSuccess {
                    var testReport = [UInt8](repeating: 0, count: 8)
                    var len: CFIndex = testReport.count
                    let res = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &testReport, &len)
                    IOHIDDeviceClose(dev, Self.noOptions)
                    
                    if res == kIOReturnSuccess && len >= 3 {
                        foundDevice = dev
                        detectedPid = pid
                        detectedProd = prod.isEmpty ? "las" : prod
                        break
                    }
                }
            }
        }
        
        if let dev = foundDevice {
            self.hidDevice = dev
            AppSettings.shared.isHardwareSensor = true
            AppSettings.shared.isClamshellMode = false
            AppSettings.shared.isSensorConnected = true
            AppSettings.shared.sensorStatusMessage = "Hardware Lid Angle Sensor connected (PID: 0x\(String(format: "%04X", detectedPid)) - \(detectedProd))."
        } else {
            // Hardware sensor not present on this machine (e.g. MacBook Neo, M1 Air, M1 Pro 13", iMac)
            activateClamshellMode(reason: "MacBook Neo / M1 without continuous LAS hardware")
        }
    }
    
    private func activateClamshellMode(reason: String) {
        self.hidDevice = nil
        AppSettings.shared.isHardwareSensor = false
        AppSettings.shared.isClamshellMode = true
        AppSettings.shared.isSensorConnected = true
        AppSettings.shared.sensorStatusMessage = "Clamshell Mode Active (MacBook Neo / M1 — Auto Sleep & Wake Animation Enabled)"
        lastKnownClamshellClosed = isLidClosedViaIORegistry()
    }
    
    private func isLidClosedViaIORegistry() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        
        if let prop = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            return prop.boolValue
        }
        return false
    }
    
    // MARK: - Clamshell Mode Simulations (MacBook Neo & M1)
    
    public func animateUnfold() {
        isSimulating = true
        simulationStartTime = CACurrentMediaTime()
        simulationDuration = 0.55
        simulationStartTurn = max(0.85, displayTurn)
        simulationTargetTurn = 0.0
        simulationStartAngle = 35.0
        simulationTargetAngle = 120.0
        AppSettings.shared.isClosing = false
    }
    
    public func animateFold() {
        isSimulating = true
        simulationStartTime = CACurrentMediaTime()
        simulationDuration = 0.45
        simulationStartTurn = displayTurn
        simulationTargetTurn = 0.85
        simulationStartAngle = 120.0
        simulationTargetAngle = 35.0
        AppSettings.shared.isClosing = true
    }
    
    public func triggerPreviewAnimation() {
        animateFold()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.animateUnfold()
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
        
        if settings.isHardwareSensor {
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
        } else {
            // Clamshell Mode (MacBook Neo, M1, etc.)
            let currentClosed = isLidClosedViaIORegistry()
            if currentClosed != lastKnownClamshellClosed {
                lastKnownClamshellClosed = currentClosed
                if currentClosed {
                    animateFold()
                } else {
                    animateUnfold()
                }
            }
            
            if isSimulating {
                let elapsed = CACurrentMediaTime() - simulationStartTime
                let t = min(1.0, elapsed / simulationDuration)
                // Smooth cubic ease out
                let ease = 1.0 - pow(1.0 - t, 3.0)
                displayTurn = simulationStartTurn + (simulationTargetTurn - simulationStartTurn) * ease
                currentRawAngle = simulationStartAngle + (simulationTargetAngle - simulationStartAngle) * ease
                settings.currentLidAngle = currentRawAngle
                
                if t >= 1.0 {
                    isSimulating = false
                    displayTurn = simulationTargetTurn
                    currentRawAngle = simulationTargetAngle
                    settings.currentLidAngle = currentRawAngle
                }
            } else if settings.isTestModeActive {
                displayTurn = settings.normalizedTurn(for: 120.0)
                currentRawAngle = 120.0 - displayTurn * 85.0
                settings.currentLidAngle = currentRawAngle
            } else {
                displayTurn = 0.0
                currentRawAngle = 120.0
                settings.currentLidAngle = 120.0
            }
        }
        
        onTurnUpdate?(displayTurn, currentRawAngle)
    }
}
