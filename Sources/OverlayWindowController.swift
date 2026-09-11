import Foundation
import AppKit

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    
    private var window: NSWindow?
    private var metalView: MetalFoldView?
    private var isCapturing = false
    private var wasZeroTurn = true
    private var isSleeping = false
    private var isLocked = false
    private var captureGeneration = 0
    private var wakeStartedAt: Date?
    private var lastWakeAt = Date.distantPast
    private var lockedTextureReady = false
    private var unlockedTextureReady = false
    private var displayGeneration = 0
    private var isPreparingFrame = false
    private var wantsOverlay = false
    private var foldCaptureStarted = false

    private func refreshLockState() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        isLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? isLocked
    }

    private func loadLockTexture() {
        captureGeneration += 1
        unlockedTextureReady = false
        foldCaptureStarted = false
        isCapturing = false
        let image = ScreenCapture.shared.fetchWallpaperImage() ?? ScreenCapture.shared.fetchBundledDefaultImage()
        lockedTextureReady = image != nil
        if let image { metalView?.updateImage(image) }
    }
    
    public override init() {
        super.init()
        refreshLockState()
        setupWindow()
        setupSleepObservers()
        
        // Capture at the start of each fold, not earlier while the desktop can change.
        // The sensor's pre-arm hint must not replace the image during a visible fold.
    }
    
    private func setupSleepObservers() {
        refreshLockState()
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.isLocked = true
            self.stopOverlay()
            self.loadLockTexture()
        }
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.isLocked = false
            self.wakeStartedAt = nil
            self.stopOverlay()
            // Do not capture the unlock transition: loginwindow may still be visible.
            // The next physical fold pre-arm captures a fresh desktop instead.
            self.captureGeneration += 1
            self.isCapturing = false
            self.unlockedTextureReady = false
            self.foldCaptureStarted = false
            self.lockedTextureReady = false
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
    }
    
    private func handleSleep() {
        isSleeping = true
        wakeStartedAt = nil
        loadLockTexture()
        stopOverlay()
        AppSettings.shared.isScreenCaptureDormant = true
    }
    
    private func handleWake() {
        isSleeping = false
        refreshLockState()
        // Workspace emits both system-wake and display-wake notifications.
        guard Date().timeIntervalSince(lastWakeAt) > 1 else { return }
        lastWakeAt = Date()
        wasZeroTurn = true
        if isLocked && AppSettings.shared.enableLockScreenPriority {
            loadLockTexture()
            updateWindowLevel()
            wakeStartedAt = Date()
        } else if !isLocked {
            // Wake and unlock notifications can arrive in either order.
            // Defer the desktop snapshot to the next fold in both cases.
            captureGeneration += 1
            isCapturing = false
            unlockedTextureReady = false
            foldCaptureStarted = false
            stopOverlay()
        }
    }

    private func setupWindow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        if AppSettings.shared.enableLockScreenPriority {
            win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        } else {
            win.level = .screenSaver
        }
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.canBecomeVisibleWithoutLogin = AppSettings.shared.enableLockScreenPriority
        win.hidesOnDeactivate = false
        win.animationBehavior = .none
        win.alphaValue = 0.0
        
        let mtkView = MetalFoldView(frame: win.contentView?.bounds ?? screen.frame)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.isPaused = true
        win.contentView = mtkView
        
        self.window = win
        self.metalView = mtkView

        // Materialize the WindowServer window before assigning its space.
        // It remains fully transparent and never becomes key.
        win.orderFrontRegardless()
        updateWindowLevel()
        if isLocked { loadLockTexture() }
    }
    
    public func update(turn: Double, angle: Double) {
        guard let win = self.window, let mv = self.metalView else { return }
        
        guard !isSleeping else { return }
        if isLocked && (!AppSettings.shared.enableLockScreenPriority || !lockedTextureReady) {
            stopOverlay()
            return
        }
        var visibleTurn = turn
        if let started = wakeStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.8 {
                // Deep sleep may resume after the lid has already reached its open angle.
                visibleTurn = max(turn, pow(max(0, 1 - elapsed / 0.8), 2))
            } else {
                wakeStartedAt = nil
            }
        }
        if visibleTurn <= 0.0001 {
            if foldCaptureStarted {
                // Discard a capture that finishes after this fold has already ended.
                captureGeneration += 1
                isCapturing = false
                unlockedTextureReady = false
                foldCaptureStarted = false
                AppSettings.shared.isScreenCaptureDormant = true
            }
            stopOverlay()
            return
        }
        if !isLocked && !foldCaptureStarted {
            // A cached texture is never proof that this fold has a fresh snapshot.
            captureGeneration += 1
            isCapturing = false
            unlockedTextureReady = false
            foldCaptureStarted = true
            stopOverlay()
        }
        if !isLocked && !unlockedTextureReady {
            stopOverlay()
            if visibleTurn > 0.0001 { captureScreenAsync() }
            return
        }
        // While locked, follow every sensor update without an elapsed-time cutoff.
        // Returning to the open angle hides the overlay; another close can start it again.
        mv.currentTurn = Float(visibleTurn)
        mv.lidTravel = Float(AppSettings.shared.startTiltAngle - AppSettings.shared.endTiltAngle)
        mv.blurStrength = Float(AppSettings.shared.blurStrength)
        mv.reflectionIntensity = Float(AppSettings.shared.reflectionIntensity)
        
        // Follow both opening and closing whenever the fold progress is nonzero.
        if visibleTurn > 0.0001 {
            if wasZeroTurn {
                wasZeroTurn = false
            }
            
            wantsOverlay = true
            if win.alphaValue == 0 && !isPreparingFrame {
                isPreparingFrame = true
                let generation = displayGeneration
                mv.onNextFrameReady = { [weak self] in
                    guard let self,
                          generation == self.displayGeneration,
                          self.wantsOverlay, !self.isSleeping else { return }
                    self.isPreparingFrame = false
                    self.window?.alphaValue = 1
                    self.window?.orderFrontRegardless()
                }
                mv.isPaused = false
                mv.draw()
            } else {
                mv.isPaused = false
            }
        } else {
            stopOverlay()
        }
    }
    
    public func stopOverlay() {
        displayGeneration += 1
        wantsOverlay = false
        isPreparingFrame = false
        metalView?.onNextFrameReady = nil
        wasZeroTurn = true
        window?.alphaValue = 0.0
        metalView?.isPaused = true
        metalView?.currentTurn = 0.0
    }
    
    public func updateWindowLevel() {
        guard let win = self.window else { return }
        win.canBecomeVisibleWithoutLogin = AppSettings.shared.enableLockScreenPriority
        let ready = LockScreenSpace.shared.configure(win, enabled: AppSettings.shared.enableLockScreenPriority)
        AppSettings.shared.lockScreenStatus = ready ? "已配置锁屏接口（待实际开盖验证）" : "锁屏显示接口不可用"
        if AppSettings.shared.enableLockScreenPriority {
            win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        } else {
            win.level = .screenSaver
        }
    }
    
    public func captureScreenAsync() {
        guard !isSleeping else { return }
        guard !isLocked else {
            if !lockedTextureReady { loadLockTexture() }
            return
        }
        guard !isCapturing else { return }
        let generation = captureGeneration
        isCapturing = true
        AppSettings.shared.isScreenCaptureDormant = false
        
        Task {
            if let image = await ScreenCapture.shared.fetchImage() {
                await MainActor.run {
                    guard generation == self.captureGeneration, !self.isLocked, !self.isSleeping else { return }
                    guard self.metalView?.updateImage(image) == true else {
                        self.isCapturing = false
                        AppSettings.shared.isScreenCaptureDormant = true
                        return
                    }
                    self.unlockedTextureReady = true
                    SharedStateManager.shared.saveScreenCache(image)
                    self.isCapturing = false
                    AppSettings.shared.lastCaptureDate = Date()
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            } else {
                await MainActor.run {
                    guard generation == self.captureGeneration else { return }
                    self.isCapturing = false
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            }
        }
    }
}
