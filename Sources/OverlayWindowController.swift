import Foundation
import AppKit

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    
    private var window: NSWindow?
    private var metalView: MetalFoldView?
    private var isCapturing = false
    private var wasZeroTurn = true
    
    public override init() {
        super.init()
        setupWindow()
        setupSleepObservers()
        
        // Connect intelligent hardware pre-arming
        LidSensor.shared.onPreArmCapture = { [weak self] in
            self?.captureScreenAsync()
        }
    }
    
    private func setupSleepObservers() {
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
        metalView?.isPaused = true
        window?.alphaValue = 0.0
        AppSettings.shared.isScreenCaptureDormant = true
    }
    
    private func handleWake() {
        if AppSettings.shared.imageSourceMode == .liveCapture {
            captureScreenAsync()
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
        win.alphaValue = 0.0
        
        let mtkView = MetalFoldView(frame: win.contentView?.bounds ?? screen.frame)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.isPaused = true
        win.contentView = mtkView
        
        self.window = win
        self.metalView = mtkView
        
        // One-time initial image load in background during app launch
        Task {
            if let img = await ScreenCapture.shared.fetchImage() {
                await MainActor.run {
                    self.metalView?.updateImage(img)
                    SharedStateManager.shared.saveScreenCache(img)
                    AppSettings.shared.lastCaptureDate = Date()
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            }
        }
    }
    
    public func update(turn: Double, angle: Double) {
        guard let win = self.window, let mv = self.metalView else { return }
        
        mv.currentTurn = Float(turn)
        mv.blurStrength = Float(AppSettings.shared.blurStrength)
        mv.reflectionIntensity = Float(AppSettings.shared.reflectionIntensity)
        
        // Only trigger when closing and turn > 0
        if turn > 0.0001 {
            if wasZeroTurn {
                wasZeroTurn = false
                // If pre-arm hasn't finished or was skipped, trigger emergency snapshot
                if AppSettings.shared.imageSourceMode == .liveCapture {
                    captureScreenAsync()
                }
            }
            
            mv.isPaused = false
            win.alphaValue = 1.0
            win.orderFrontRegardless()
        } else {
            wasZeroTurn = true
            win.alphaValue = 0.0
            mv.isPaused = true
        }
    }
    
    public func stopOverlay() {
        wasZeroTurn = true
        window?.alphaValue = 0.0
        metalView?.isPaused = true
        metalView?.currentTurn = 0.0
    }
    
    public func updateWindowLevel() {
        guard let win = self.window else { return }
        if AppSettings.shared.enableLockScreenPriority {
            win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        } else {
            win.level = .screenSaver
        }
    }
    
    public func captureScreenAsync() {
        guard !isCapturing else { return }
        isCapturing = true
        AppSettings.shared.isScreenCaptureDormant = false
        
        Task {
            if let image = await ScreenCapture.shared.fetchImage() {
                await MainActor.run {
                    self.metalView?.updateImage(image)
                    SharedStateManager.shared.saveScreenCache(image)
                    self.isCapturing = false
                    AppSettings.shared.lastCaptureDate = Date()
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            } else {
                await MainActor.run {
                    self.isCapturing = false
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            }
        }
    }
}
