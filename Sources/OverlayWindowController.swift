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
        
        mv.currentTurn = Float(turn)
        
        // Only trigger when closing and turn > 0
        if turn > 0.0001 {
            if wasZeroTurn {
                wasZeroTurn = false
                // Trigger fresh screen capture on initial closing tilt
                captureScreenAsync()
            }
            
            mv.isPaused = false
            win.alphaValue = 1.0
            win.orderFrontRegardless()
        } else {
            // When user is using MacBook (or opening): do nothing, keep completely invisible
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
