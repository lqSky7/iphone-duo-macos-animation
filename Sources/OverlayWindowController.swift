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
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.alphaValue = 0.0
        
        let mtkView = MetalFoldView(frame: win.contentView?.bounds ?? screen.frame)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.isPaused = true
        win.contentView = mtkView
        
        self.window = win
        self.metalView = mtkView
        
        // Initial image load in background
        Task {
            if let img = await ScreenCapture.shared.fetchImage() {
                await MainActor.run {
                    self.metalView?.updateImage(img)
                }
            }
        }
    }
    
    public func update(turn: Double, angle: Double) {
        guard let win = self.window, let mv = self.metalView else { return }
        
        let settings = AppSettings.shared
        
        // Mode: 0 for clamshell, 1 for bookLeft, 2 for bookRight
        let hingeMode = settings.hingeMode
        let mode: Int32 = hingeMode == .clamshell ? 0 : 1
        let hinge: Float = hingeMode == .bookRight ? 1.0 : 0.0
        
        mv.currentTurn = Float(turn)
        mv.currentHinge = hinge
        mv.currentMode = mode
        
        if turn > 0.0001 {
            if wasZeroTurn {
                wasZeroTurn = false
                // Trigger fresh screen capture on initial tilt
                captureScreenAsync()
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
    
    public func captureScreenAsync() {
        guard !isCapturing else { return }
        isCapturing = true
        Task {
            if let image = await ScreenCapture.shared.fetchImage() {
                await MainActor.run {
                    self.metalView?.updateImage(image)
                    self.isCapturing = false
                }
            } else {
                self.isCapturing = false
            }
        }
    }
}
