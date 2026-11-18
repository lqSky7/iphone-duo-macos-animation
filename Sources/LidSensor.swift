import Foundation
import AppKit
import IOKit
import IOKit.hid
import QuartzCore

public final class LidSensor {
    public static let shared = LidSensor()
    
    /// turn = eased display value (hysteresis/UI/menus), targetTurn = the
    /// pre-easing target the render loop applies its own follow filter to.
    /// Publishing both lets the view ease at display-link cadence without
    /// double-filtering (which would double the lag the lead predictor was
    /// tuned against).
    public typealias TurnCallback = (_ turn: Double, _ angle: Double, _ targetTurn: Double) -> Void
    public var onTurnUpdate: TurnCallback?
    public var onPreArmCapture: (() -> Void)?
    
    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private var isDeviceOpen = false
    private var timer: Timer?
    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)

    // P0-1: HID I/O lives on its own queue. IOHIDDeviceGetReport blocks on a
    // kernel/SPU round-trip, so it must never run on the main runloop.
    // Main thread keeps easing/interpolation/consumption only.
    private let hidQueue = DispatchQueue(label: "com.mactilt.hid", qos: .userInitiated)
    private let hidStateLock = NSLock()
    private var _latestRawAngle: Double = 120.0
    private var _latestSampleTime: CFTimeInterval = 0
    private var _latestReadOK: Bool = false
    private var _readFailStreak: Int = 0
    private var hidTimer: DispatchSourceTimer?
    // Reopen storm guard (main-confined, tick context): without a throttle,
    // every silent tick enqueues a close+open block behind the hung GetReport
    // it is meant to recover from — an infinite syscall loop at up to 120Hz.
    private var lastReopenAttempt: CFTimeInterval = 0
    // Ease-rate pin (main-confined): transient overrides of adaptPollInterval,
    // e.g. holding 60Hz through the 90ms open fade after stillness decayed
    // the clock to 10Hz. Zero = no pin.
    private var ratePinInterval: Double = 0
    private var ratePinUntil: CFTimeInterval = 0
    // Clamshell-path IOKit cache: IOService matching + registry reads every
    // tick is a kernel IPC at 10..120Hz for every no-sensor Mac. 1Hz is plenty.
    private var lastClamshellPoll: CFTimeInterval = 0
    private var cachedClamshellClosed: Bool = false
    
    // Physics and motion tracking
    private var lastTime: CFTimeInterval?
    public private(set) var displayTurn: Double = 0.0
    public private(set) var targetTurn: Double = 0.0
    public private(set) var currentRawAngle: Double = 120.0
    private var isActivelyClosing: Bool = false
    private var hasPreArmedInThisMotion: Bool = false

    // Clamshell truthfulness: smoothed angular velocity (deg/sec, negative = closing).
    // Derived from actual HID sample timestamps — immune to timer-phase aliasing.
    public private(set) var smoothedVelocity: Double = 0.0
    private var prevConsumedAngle: Double = 120.0
    private var prevConsumedSampleTime: CFTimeInterval = 0
    private var stillSince: CFTimeInterval? = nil

    // α-β lead predictor (main-confined, tick context): masks the residual
    // 30-80ms phase lag so the fold leads the finger instead of trailing it.
    // Deliberately α-β, never α-β-γ: over a ~60ms lead, accel contributes
    // ½·a·t² ≤ ~2° even at physical clamp — sub-frame — while the γ/dt² path
    // amplifies integer-quantum noise 144× across the 10→120Hz dt swing.
    // Deleted on evidence, not tuned on hope. Lead retuned to 60ms to match
    // the easing lag (τ=1/followSpeed≈62ms): prediction must dominate lag,
    // not trail it.
    private var predX: Double = 120.0
    private var predV: Double = 0.0
    private static let predLeadTime: Double = 0.06
    private static let predMaxLead: Double = 8.0

    /// α-β step on a fresh HID sample. β is scheduled with dt: fixed gains
    /// are only steady-state-optimal at a fixed rate, and our clock swings
    /// 12×. Snaps (never predicts) through discontinuities. Reuses
    /// prevConsumedSampleTime as its clock — one timestamp, one dt.
    private func updatePredictor(angle: Double, sampleTime: CFTimeInterval) {
        let lastT = prevConsumedSampleTime
        if lastT <= 0 {
            predX = angle
            predV = 0
            return
        }
        let rawDt = sampleTime - lastT
        // Backwards/duplicate delivery or sleep/wake gap: re-init, never
        // divide by zero or a negative dt (sign-flipped, amplified kick).
        guard rawDt > 0, rawDt <= 1.0 else {
            predX = angle
            predV = 0
            return
        }
        let dt = max(rawDt, 1.0 / 240.0)
        // Velocity gate, not position jump: a 300°/s slam legitimately covers
        // 30°+ per 10Hz tick; only unphysical slew snaps the filter.
        if abs(angle - predX) / dt > 1200.0 {
            predX = angle
            predV = 0
            return
        }
        // Predict to the sample instant, then correct. Fixed β: the residual
        // is already dt-normalized (β·residual/dt), so scheduling β with dt
        // on top double-counts the rate and pumps noise across 10→120Hz.
        let beta = 0.08
        let xPred = predX + predV * dt
        let residual = angle - xPred
        predX = xPred + 0.35 * residual
        predV += beta * residual / dt
    }

    /// Lead angle driving targetTurn. Frozen to measured unless actively
    /// tracking (live samples flowing AND stillness not confirmed) — it can
    /// never overshoot a stop, a reversal, or a sensor dropout. Notably, slow
    /// stared-at folds keep their lead: the gate is confirmed stillness
    /// (200ms), not the first quiet tick. Capture thresholds and published
    /// angles stay on measured values; only the rendered turn leads.
    private func predictedAngle(measured: Double, tracking: Bool, still: Bool) -> Double {
        guard tracking, !still else { return measured }
        let lead = predX + predV * Self.predLeadTime
        return min(max(lead, measured - Self.predMaxLead, 0.0),
                   measured + Self.predMaxLead, 180.0)
    }

    // Duo mode replay. Measured on a real lid: polled at 120 Hz, the value only
    // changes every ~100 ms, in 2–15° jumps. A picture meant to stand still shows
    // every jump, so Duo mode plays each new value in as a straight line from where
    // it is now over the last measured interval: ~one interval of lag, but
    // continuous and never overshooting (≈7× less jerk on the recorded data).
    private var duoFrom: Double = 120.0
    private var duoTo: Double = 120.0
    private var duoChangeTime: CFTimeInterval = 0
    private var duoInterval: Double = 0.1

    private func duoReplayValue(at now: CFTimeInterval) -> Double {
        let p = min(max((now - duoChangeTime) / duoInterval, 0.0), 1.0)
        return duoFrom + (duoTo - duoFrom) * p
    }

    private func duoReplayedAngle(measured: Double) -> Double {
        let now = CACurrentMediaTime()
        if duoChangeTime == 0 || now - duoChangeTime > 2.0 {
            // First use or long idle: start where the lid is, no sweep in from a stale value.
            duoFrom = measured; duoTo = measured; duoChangeTime = now
        } else if measured != duoTo {
            let gap = now - duoChangeTime
            duoInterval = (gap > 0.02 && gap < 0.3) ? gap : 0.1
            duoFrom = duoReplayValue(at: now)
            duoTo = measured
            duoChangeTime = now
        }
        return duoReplayValue(at: now)
    }

    // Adaptive polling: Feature Reports must be polled (no Input Reports from LAS),
    // so vary the rate instead — 10Hz idle, 60Hz armed, 120Hz while closing.
    private var workspaceObservers: [NSObjectProtocol] = []
    private var currentPollInterval: Double = 1.0 / 60.0
    // Epoch guards the slot against stale fires from a cancelled HID timer:
    // cancel() never interrupts an in-flight handler, so the handler must
    // prove it belongs to the current timer before publishing.
    private var hidPollEpoch: UInt64 = 0
    
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
        guard workspaceObservers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        })
    }

    private func removeWakeAndSleepObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            ws.removeObserver(token)
        }
        workspaceObservers.removeAll()
    }
    
    public func handleWake() {
        if AppSettings.shared.isHardwareSensor {
            // Quiesce sampling, then re-enumerate OFF-main: setupManager
            // blocks on IOHIDManagerOpen + per-device probe GetReports.
            hidTimer?.cancel()
            hidTimer = nil
            bumpHIDPollEpoch()
            let reschedule = (timer != nil)
            let interval = currentPollInterval
            hidQueue.async { [weak self] in
                guard let self else { return }
                self.setupManager()
                self.reopenHIDIfNeeded()
                if reschedule {
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleHIDTimer(interval: interval)
                    }
                }
            }
        } else {
            // Clamshell mode: on wake / opening from sleep, animate unfold
            animateUnfold()
        }
    }
    
    public func handleWillSleep() {
        // Closing animation is not possible without continuous LAS hardware;
        // screen shuts off immediately when the lid switch closes.
    }
    
    /// Runs bodies on main without deadlocking when already there.
    /// setupManager/probing may run on hidQueue (post-wake) or main (init).
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Is Apple's lid angle sensor present on this machine? Answered from the
    /// IORegistry alone — no IOHIDManager, no device opens, no permission of any
    /// kind. This is what keeps the HID probe off machines that have nothing to
    /// probe for.
    ///
    /// Positive identification only. An inconclusive or failed enumeration
    /// returns false, which sends the caller down the HID path exactly as
    /// before: this is a fast path and a permission avoidance, never the thing
    /// that can wrongly declare a sensor Mac sensorless.
    static func lidAngleSensorPresentInIORegistry() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator
        ) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }

        func property(_ service: io_service_t, _ key: String) -> CFTypeRef? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            let product = (property(service, kIOHIDProductKey) as? String) ?? ""
            if product.lowercased() == "las" { return true }

            // Sensors page 0x20, orientation usage 0x8A: what actually separates
            // the lid sensor from the other sensor-hub devices.
            let pid = (property(service, kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0
            let page = (property(service, kIOHIDPrimaryUsagePageKey) as? NSNumber)?.intValue ?? 0
            let usage = (property(service, kIOHIDPrimaryUsageKey) as? NSNumber)?.intValue ?? 0
            if pid == 0x8104, page == 0x0020, usage == 0x008A { return true }
        }
        return false
    }

    private func setupManager() {
        // Ask the IORegistry first. Only a machine that positively has a lid
        // angle sensor goes on to open an IOHIDManager at all.
        //
        // This matters most on the machines that have no sensor — MacBook Neo,
        // M1 Air, M1 Pro 13", any desktop. They used to pay for the HID probe
        // anyway: create a manager, enumerate every HID device on the system,
        // then open the accelerometer, the gyroscope and the ambient light
        // sensor before concluding "nothing here". That is a lot of
        // input-hardware access to answer a question the IORegistry answers for
        // free. Now those machines never touch HID, so there is nothing for
        // macOS to ask about.
        guard AppSettings.isLidAngleSensorProbeEnabled else {
            activateClamshellMode(reason: "lid angle sensor probe disabled in Settings")
            return
        }
        guard Self.lidAngleSensorPresentInIORegistry() else {
            activateClamshellMode(reason: "no continuous lid angle sensor on this Mac (MacBook Neo / M1 class)")
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)

        // MATCH FIRST, OPEN SECOND.
        //
        // IOHIDManagerOpen with no criteria set matches EVERY HID device on the
        // system, keyboard included, before the criteria below can narrow it.
        // That is a strictly wider association with input hardware than macTilt
        // has any use for, and a wide-open manager is exactly the shape macOS
        // treats as "this app wants the keyboard" — the Input Monitoring /
        // "Keystroke Receiving" consent alert. Narrowing first means the manager
        // is never associated with an input device at any point.
        //
        // macTilt does not need Input Monitoring at all: it reads one feature
        // report from one sensor and never listens for input events. Denying the
        // alert was always harmless, which is why the sensor kept working when
        // it was dismissed — the alert should not have been raised.
        let matchingCriteria: [[String: Any]] = [
            // Apple's lid angle sensor, by identity.
            [
                kIOHIDVendorIDKey as String: 0x05AC,
                kIOHIDProductIDKey as String: 0x8104
            ],
            // ...and by the sensor usages it declares (page 0x20 = Sensors,
            // usage 0x8A = Orientation). Primary usage and device usage are
            // distinct keys and hardware is inconsistent about which one it
            // populates, so both are listed.
            [
                kIOHIDPrimaryUsagePageKey as String: 0x0020,
                kIOHIDPrimaryUsageKey as String: 0x008A
            ],
            [
                kIOHIDDeviceUsagePageKey as String: 0x0020,
                kIOHIDDeviceUsageKey as String: 0x008A
            ]
        ]
        // Deliberately NOT a criterion: a bare kIOHIDProductKey == "las" match.
        // A string-only dictionary is the one shape the HID matching layer
        // cannot classify as "not an input device", so it undoes the point of
        // matching narrowly. The product name is still honoured — as a property
        // filter on devices that the criteria above already matched (see the
        // isCandidate test below), which is the safe direction to use it in.
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingCriteria as CFArray)

        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess else {
            // A denied Input Monitoring grant also lands here. Nothing is lost:
            // the fallback below is the same clamshell path used on Macs with
            // no sensor at all.
            activateClamshellMode(reason: "HID access unavailable")
            return
        }
        self.hidManager = manager

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            activateClamshellMode(reason: "no lid angle sensor found")
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
            
            // Only the lid angle sensor itself is a candidate.
            //
            // PID 0x8104 is Apple's sensor-hub product ID and is shared by the
            // accelerometer, the gyroscope and the ambient light sensor, so it
            // is NOT on its own evidence of the right device. Treating it as
            // such made the probe open all three on every launch — input
            // hardware macTilt has no use for and never reads. The Sensors-page
            // orientation usage is what actually identifies the lid sensor; the
            // product name covers hardware that reports a vendor-specific page.
            let isCandidate = prod.lowercased() == "las" ||
                              prod.lowercased().contains("lid") ||
                              prod.lowercased().contains("angle") ||
                              (page == 32 && usage == 138)
            
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
            hidStateLock.lock()
            self.hidDevice = dev
            hidStateLock.unlock()
            onMain {
                AppSettings.shared.isHardwareSensor = true
                AppSettings.shared.isClamshellMode = false
                AppSettings.shared.isSensorConnected = true
                AppSettings.shared.sensorStatusMessage = "Hardware Lid Angle Sensor connected (PID: 0x\(String(format: "%04X", detectedPid)) - \(detectedProd))."
            }
        } else {
            // Hardware sensor not present on this machine (e.g. MacBook Neo, M1 Air, M1 Pro 13", iMac)
            activateClamshellMode(reason: "no continuous lid angle sensor on this Mac (MacBook Neo / M1 class)")
        }
    }
    
    /// `reason` is a lowercase clause completed into the status line. It is the
    /// only place a denied Input Monitoring grant becomes visible, so it has to
    /// stay honest instead of blaming the hardware for it.
    private func activateClamshellMode(reason: String) {
        hidStateLock.lock()
        self.hidDevice = nil
        self.isDeviceOpen = false
        hidStateLock.unlock()
        let closed = isLidClosedViaIORegistry()
        onMain {
            AppSettings.shared.isHardwareSensor = false
            AppSettings.shared.isClamshellMode = true
            AppSettings.shared.isSensorConnected = true
            AppSettings.shared.sensorStatusMessage = "Clamshell Mode Active — \(reason). Lid-open animation enabled."
        }
        lastKnownClamshellClosed = closed
    }
    
    /// Physical lid-closed signal for the overlay's clamshell suppression:
    /// registry state on no-sensor Macs (1Hz cache), near-shut angle on
    /// hardware-sensor Macs. Main-thread only (reads published state).
    public var isLidPhysicallyClosed: Bool {
        if AppSettings.shared.isClamshellMode {
            return cachedClamshellClosed
        }
        return currentRawAngle < AppSettings.shared.endTiltAngle + 5.0
    }

    private func isLidClosedViaIORegistry() -> Bool {        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
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
        simulationDuration = AppSettings.shared.clamshellOpeningDuration
        simulationStartTurn = max(0.85, displayTurn)
        simulationTargetTurn = 0.0
        simulationStartAngle = 35.0
        simulationTargetAngle = 120.0
        AppSettings.shared.isClosing = false
    }
    
    public func triggerOpeningPreview() {
        StreamCapture.shared.prime()
        animateUnfold()
    }
    
    public func animateFold() {
        // Closing animation is not possible on no-LAS Macs
    }
    
    /// Tear the hardware detection down and run it again from scratch. Used when
    /// the user flips the sensor-probe setting: the running configuration has to
    /// be rebuilt, and setupManager is the only path that does that. stop() and
    /// start() both hop onto the same serial HID queue, so the teardown is
    /// guaranteed to land before the re-probe.
    public func reprobeHardware() {
        stop()
        hidStateLock.lock()
        hidDevice = nil
        isDeviceOpen = false
        hidStateLock.unlock()
        currentRawAngle = 120.0
        displayTurn = 0.0
        targetTurn = 0.0
        start()
    }

    public func start() {
        guard timer == nil else { return }
        // stop() removes wake observers and closes HID state; rebuild both
        // here (guards are idempotent). Enumeration runs off-main.
        setupWakeAndSleepObservers()
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.hidStateLock.lock()
            let hasDevice = self.hidDevice != nil
            self.hidStateLock.unlock()
            if !hasDevice {
                self.setupManager()
            }
            self.hidStateLock.lock()
            let device = self.hidDevice
            let opened = self.isDeviceOpen
            self.hidStateLock.unlock()
            if let device, !opened,
               IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess {
                self.hidStateLock.lock()
                self.isDeviceOpen = true
                self.hidStateLock.unlock()
            }
        }
        scheduleHIDTimer(interval: currentPollInterval)
        scheduleEaseTimer(interval: currentPollInterval)
    }

    // MARK: - Dual timers: HID sampling (background) + easing (main)

    private func scheduleEaseTimer(interval: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            // Always .common: runloop membership is additive and never
            // removed, so conditional membership ratchets to .common
            // permanently anyway — and easing must not freeze while the user
            // drags a menu mid-close. Battery comes from tolerance, which the
            // system uses to coalesce idle fires with other timers.
            RunLoop.main.add(t, forMode: .common)
            let active = isActivelyClosing || displayTurn > 0.001
            t.tolerance = active ? 0 : interval * 0.2
        }
    }

    /// Epoch bump: retires the current HID timer generation so any handler
    /// that unblocks after cancel (cancel never interrupts in-flight work)
    /// fails its post-check instead of publishing into a new regime.
    private func bumpHIDPollEpoch() {
        hidStateLock.lock()
        hidPollEpoch &+= 1
        hidStateLock.unlock()
    }

    private func scheduleHIDTimer(interval: Double) {
        hidTimer?.cancel()
        hidStateLock.lock()
        hidPollEpoch &+= 1
        let epoch = hidPollEpoch
        hidStateLock.unlock()
        let t = DispatchSource.makeTimerSource(queue: hidQueue)
        let leeway: DispatchTimeInterval = isActivelyClosing
            ? .nanoseconds(0)
            : .milliseconds(max(1, Int(interval * 200.0)))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        t.setEventHandler { [weak self] in
            self?.pollHIDOnce(epoch: epoch)
        }
        t.resume()
        hidTimer = t
    }

    /// Blocking Feature Report read. ALWAYS on hidQueue, never main.
    /// Stale fires from a cancelled timer prove epoch before publishing.
    private func pollHIDOnce(epoch: UInt64) {
        hidStateLock.lock()
        let device = hidDevice
        let opened = isDeviceOpen
        let current = hidPollEpoch
        hidStateLock.unlock()
        guard opened, let device, epoch == current else { return }

        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        hidStateLock.lock()
        defer { hidStateLock.unlock() }
        // Re-check epoch AND open state: a re-arm, stop(), or device
        // replacement may have landed while we blocked in the kernel.
        guard epoch == hidPollEpoch, isDeviceOpen else { return }
        if result == kIOReturnSuccess, length >= 3 {
            let rawValue = UInt16(report[2]) << 8 | UInt16(report[1])
            _latestRawAngle = Double(rawValue)
            _latestSampleTime = CACurrentMediaTime()
            _latestReadOK = true
            _readFailStreak = 0
        } else {
            _readFailStreak += 1
            if _readFailStreak > 30 {
                _latestReadOK = false
            }
        }
    }

    private func reopenHIDIfNeeded() {
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.hidStateLock.lock()
            let device = self.hidDevice
            let opened = self.isDeviceOpen
            self.hidStateLock.unlock()
            guard let dev = device else { return }
            if opened {
                IOHIDDeviceClose(dev, Self.noOptions)
            }
            let ok = IOHIDDeviceOpen(dev, Self.noOptions) == kIOReturnSuccess
            self.hidStateLock.lock()
            self.isDeviceOpen = ok
            if ok {
                self._readFailStreak = 0
                // Optimistic: a successful open means the next poll should
                // produce — the throttled tick stops queueing reopens until
                // the poll either confirms (fresh sample) or denies (streak).
                self._latestReadOK = true
            }
            self.hidStateLock.unlock()
        }
    }

    /// Close onset must not wait for the 2-tick stability gate: a close
    /// starting from 10Hz idle would otherwise lag ~200ms — the exact hitch
    /// users feel. Opening/downward motion kicks 120Hz immediately.
    private func kickHighRateIfNeeded() {
        let fast = 1.0 / 120.0
        guard abs(currentPollInterval - fast) > 0.0001 else { return }
        currentPollInterval = fast
        stableDesiredInterval = fast
        stableIntervalTicks = 0
        scheduleHIDTimer(interval: fast)
        scheduleEaseTimer(interval: fast)
    }

    /// Pin the ease+HID rate transiently, bypassing the stability gate.
    /// Used for the open fade (60Hz through 90ms after a 10Hz idle decay).
    public func pinRate(_ interval: Double, for duration: Double) {
        ratePinInterval = interval
        ratePinUntil = CACurrentMediaTime() + duration
    }

    /// Adaptive rate control — called at the end of tick(). Keeps zero-idle-cost
    /// promise: 10Hz when parked open, 60Hz when armed, 120Hz while closing.
    /// Re-arms both timers only on stable transitions (no runloop churn).
    private var stableDesiredInterval: Double = 1.0 / 60.0
    private var stableIntervalTicks: Int = 0
    private var parkAngle: Double = 120.0
    private var parkSince: CFTimeInterval = 0
    private func adaptPollInterval(angle: Double) {
        // Transient pin wins (open fade): hold the requested rate through
        // its deadline without touching the stability tracker.
        if ratePinInterval > 0 {
            if CACurrentMediaTime() < ratePinUntil {
                if abs(ratePinInterval - currentPollInterval) > 0.0001 {
                    currentPollInterval = ratePinInterval
                    scheduleHIDTimer(interval: ratePinInterval)
                    scheduleEaseTimer(interval: ratePinInterval)
                }
                return
            }
            ratePinInterval = 0
        }
        let settings = AppSettings.shared
        // Parked: no fold on screen and the lid hasn't moved more than 2° for a
        // second (sensor dither is ±1°). The sensor only changes ~10×/s anyway,
        // and the first downward sample still kicks 120 Hz immediately, so a lid
        // resting in the arm zone (normal use with a high start angle) no longer
        // pays for 60 Hz polling forever.
        let nowRate = CACurrentMediaTime()
        if abs(angle - parkAngle) > 2.0 {
            parkAngle = angle
            parkSince = nowRate
        }
        let parked = displayTurn <= 0.001 && nowRate - parkSince > 1.0
        let desired: Double
        if isActivelyClosing {
            desired = 1.0 / 120.0
        } else if !parked && (!settings.isScreenCaptureDormant || angle <= min(135.0, settings.startTiltAngle + 15.0) || displayTurn > 0.001) {
            desired = 1.0 / 60.0
        } else {
            desired = 1.0 / 10.0
        }
        if abs(desired - stableDesiredInterval) > 0.0001 {
            stableDesiredInterval = desired
            stableIntervalTicks = 0
        } else {
            stableIntervalTicks += 1
        }
        if stableIntervalTicks == 2, abs(desired - currentPollInterval) > 0.0001 {
            currentPollInterval = desired
            scheduleHIDTimer(interval: desired)
            scheduleEaseTimer(interval: desired)
        }
    }
    
    public func stop() {
        timer?.invalidate()
        timer = nil
        hidTimer?.cancel()
        hidTimer = nil
        bumpHIDPollEpoch()
        removeWakeAndSleepObservers()
        // Async close: never block the caller behind an in-flight GetReport.
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.hidStateLock.lock()
            let device = self.hidDevice
            let opened = self.isDeviceOpen
            let manager = self.hidManager
            self.hidStateLock.unlock()
            if opened, let device {
                IOHIDDeviceClose(device, Self.noOptions)
                self.hidStateLock.lock()
                self.isDeviceOpen = false
                self.hidStateLock.unlock()
            }
            if let manager {
                IOHIDManagerClose(manager, Self.noOptions)
                self.hidStateLock.lock()
                if self.hidManager === manager {
                    self.hidManager = nil
                }
                self.hidStateLock.unlock()
            }
        }
    }
    
    private func tick() {
        let settings = AppSettings.shared
        
        if settings.isHardwareSensor {
            // Consume the latest angle sampled on hidQueue. Main thread never
            // blocks on the kernel here — worst case we reuse last tick's value.
            hidStateLock.lock()
            let angle = _latestRawAngle
            let sampleTime = _latestSampleTime
            let readOK = _latestReadOK
            hidStateLock.unlock()

            if !readOK {
                // Sensor silent (sleep/wake gap) — re-establish off-main, at
                // most 1Hz: unthrottled, every silent tick enqueues a close+open
                // block behind the hung GetReport it means to recover from.
                let nowSilent = CACurrentMediaTime()
                if nowSilent - lastReopenAttempt > 1.0 {
                    lastReopenAttempt = nowSilent
                    reopenHIDIfNeeded()
                }
            }

            // Lead tracking is gated on sample AGE, not per-tick freshness.
            // The HID poll timer and the ease timer share a nominal rate but
            // are NOT phase-locked (and the main-runloop ease timer jitters
            // against 120fps draw callbacks), so a large fraction of ticks
            // see no NEW sample even while the sensor streams perfectly.
            // Gating the lead on per-tick freshness oscillated the render
            // target between measured and measured+lead (up to 8° ≈ 7% of
            // the fold range) at the timer beat frequency — low-frequency,
            // exactly where the render-side follow filter cannot attenuate
            // it. That was the dominant real-lid jitter; preview never runs
            // the predictor, which is why preview looked smooth. The lead is
            // now held while the newest sample is young (≥100ms, or 3 poll
            // intervals at low rates); only a genuinely silent sensor falls
            // back to measured.
            var trackingSample = false
            var leadHoldStill = true

            if readOK {
                let nowTick = CACurrentMediaTime()
                let sampleAge = nowTick - sampleTime
                trackingSample = sampleAge < max(0.1, currentPollInterval * 3.0)
                // Direction steered by dt-normalized VELOCITY (deg/sec), not
                // per-tick delta: the adaptive clock runs 10..120Hz, so a
                // genuine 30°/s close reads 3°/tick idle but 0.25°/tick at
                // 120Hz — per-tick thresholds flap the rate they steer.
                var instVelocity: Double = 0
                var hasFreshSample = false
                if sampleTime > prevConsumedSampleTime {
                    if prevConsumedSampleTime > 0 {
                        let dtSample = max(sampleTime - prevConsumedSampleTime, 1.0 / 240.0)
                        instVelocity = min(max((angle - prevConsumedAngle) / dtSample, -1200.0), 1200.0)
                        smoothedVelocity += (instVelocity - smoothedVelocity) * 0.25
                    }
                    updatePredictor(angle: angle, sampleTime: sampleTime)
                    prevConsumedAngle = angle
                    prevConsumedSampleTime = sampleTime
                    hasFreshSample = true
                } else if sampleAge > currentPollInterval * 2.5 {
                    // Genuinely starved of samples (dropout), not phase-
                    // aliased: decay time-consistently over the actual gap.
                    // A stale tick INSIDE 2.5 intervals is a strict no-op —
                    // the old unconditional decay sawtoothed velocity while
                    // data flowed, flickering the direction flags and the
                    // 120↔60Hz poll-rate decision (which rescheduled the
                    // timers and fed the aliasing loop).
                    smoothedVelocity *= exp(-min(sampleAge, 0.3) / 0.08)
                }

                // Raw sample fires the 120Hz kick (a spurious bump only costs
                // a rate change); smoothed velocity drives committed state.
                if hasFreshSample && instVelocity < -6.0 {
                    kickHighRateIfNeeded()
                }
                let isMovingDownward = smoothedVelocity < -12.0
                let isMovingUpward = smoothedVelocity > 18.0

                if isMovingDownward {
                    isActivelyClosing = true
                    stillSince = nil
                } else if isMovingUpward {
                    isActivelyClosing = false
                    hasPreArmedInThisMotion = false
                    stillSince = nil
                    // Committed reversal: kill stale closing velocity now, not
                    // 200ms later — otherwise the lead pushes further closed
                    // while the finger opens.
                    predV = 0
                } else {
                    // Sub-threshold drift with live samples counts as motion:
                    // after any hesitation, a slow resume must re-arm the
                    // lead instead of latching leadless until a fast flick.
                    // Stillness ONSET is judged only on fresh samples: a
                    // phase-aliased stale tick is "no information", never
                    // evidence of stillness (stale ticks used to start the
                    // 200ms clock mid-motion).
                    if hasFreshSample && abs(instVelocity) > 2.5 {
                        stillSince = nil
                    } else if hasFreshSample && stillSince == nil {
                        // Time-based stillness (200ms), not frame-counted: the
                        // adaptive clock runs 10..120Hz, so frame counts lie.
                        stillSince = nowTick
                    } else if let since = stillSince, nowTick - since > 0.2 {
                        isActivelyClosing = false
                        // Freeze the predictor with the stop: stale velocity
                        // would otherwise overshoot into the reversal.
                        predV = 0
                    }
                }
                // Confirmed stillness is a pure function of (stillSince, now):
                // no second flag to drift out of sync with the first.
                leadHoldStill = stillSince.map { nowTick - $0 > 0.2 } ?? false

                // If lid is safely open, reset pre-arm latch and mark capture engine dormant
                if angle >= settings.startTiltAngle || (!isActivelyClosing && angle >= settings.startTiltAngle - 10.0) {
                    hasPreArmedInThisMotion = false
                    // @Published fires objectWillChange on EVERY assignment,
                    // even no-op ones — this branch runs per-tick while the
                    // lid is parked open, so gate on actual change.
                    if settings.isScreenCaptureDormant != true {
                        settings.isScreenCaptureDormant = true
                    }
                }

                // Hardware Pre-Arming Capture Zone: threshold scales with close
                // speed so slams prime earlier (stream start costs 30-150ms).
                // The motion latch (not a time throttle) gives once-per-motion:
                // a quicker re-prime on open→re-close is strictly better, and
                // prime() is a no-op when already warm.
                let closeSpeed = min(max(-smoothedVelocity, 0.0), 600.0)
                let preArmThreshold = min(160.0, settings.startTiltAngle + 25.0 + closeSpeed * 0.03)
                if angle <= preArmThreshold && angle < settings.startTiltAngle {
                    if !hasPreArmedInThisMotion {
                        hasPreArmedInThisMotion = true
                        settings.isScreenCaptureDormant = false
                        onPreArmCapture?()
                    }
                }

                currentRawAngle = angle
                // Gated @Published writes: objectWillChange fires on every
                // assignment, so an open Settings window would re-render up to
                // 120x/s on unchanged values. Equality-gate everything that
                // usually doesn't change.
                if settings.currentLidAngle != angle {
                    settings.currentLidAngle = angle
                }
                if settings.isClosing != isActivelyClosing {
                    settings.isClosing = isActivelyClosing
                }
                if !settings.isSensorConnected {
                    settings.isSensorConnected = true
                }
            }
            
            // Target turn leads the finger: predicted angle masks HID + pipeline
            // latency. Measured angle still drives capture thresholds and UI.
            // Leads only on live samples: dropout holds measured, confirmed
            // stillness holds measured, everything else leads up to ±8°.
            targetTurn = settings.normalizedTurn(for: settings.duoMode
                ? duoReplayedAngle(measured: currentRawAngle)
                : predictedAngle(measured: currentRawAngle, tracking: trackingSample, still: leadHoldStill))
            
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
            // Clamshell Mode (MacBook Neo, M1, etc.) — registry polled at 1Hz
            // and cached; per-tick IOService matching is a kernel table walk.
            let nowClam = CACurrentMediaTime()
            if nowClam - lastClamshellPoll > 1.0 {
                lastClamshellPoll = nowClam
                cachedClamshellClosed = isLidClosedViaIORegistry()
            }
            let currentClosed = cachedClamshellClosed
            if currentClosed != lastKnownClamshellClosed {
                lastKnownClamshellClosed = currentClosed
                if currentClosed {
                    // Closed: screen backlight cuts off immediately; do not animate close
                    isSimulating = false
                    displayTurn = 0.0
                } else {
                    // Opened: trigger customizable opening unfold animation
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
            // Off-hardware paths drive displayTurn directly: keep the public
            // targetTurn honest instead of leaking a stale hardware value.
            targetTurn = displayTurn
        }
        
        adaptPollInterval(angle: currentRawAngle)
        onTurnUpdate?(displayTurn, currentRawAngle, targetTurn)
    }
}
