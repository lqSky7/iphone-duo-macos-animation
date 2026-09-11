import Foundation
import ScreenSaver
import AppKit
import MetalKit

@objc(MacTiltScreenSaverView)
public final class MacTiltScreenSaverView: ScreenSaverView {
    private var metalView: MetalFoldView?
    private var currentTurn: Double = 0.0
    private var targetTurn: Double = 0.0
    private var isFoldDormant: Bool = true
    
    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        self.animationTimeInterval = 1.0 / 60.0
        setupView()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.animationTimeInterval = 1.0 / 60.0
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        let mtk = MetalFoldView(frame: bounds)
        mtk.autoresizingMask = [.width, .height]
        mtk.isPaused = true // Start completely paused for 0% idle battery burn
        addSubview(mtk)
        self.metalView = mtk
        
        loadTexture()
    }
    
    private func loadTexture() {
        // Priority 1: Crisp snapshot cached by macTilt.app right before sleep
        if let cached = SharedStateManager.shared.loadScreenCache() {
            metalView?.updateImage(cached)
            return
        }
        
        // Priority 2: Current desktop wallpaper
        if let screen = NSScreen.main,
           let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let img = NSImage(contentsOf: url),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            metalView?.updateImage(cg)
            return
        }
        
        // Priority 3: Bundled default artwork
        let bundle = Bundle(for: Self.self)
        if let bundleUrl = bundle.url(forResource: "default", withExtension: "png"),
           let img = NSImage(contentsOf: bundleUrl),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            metalView?.updateImage(cg)
        }
    }
    
    public override func startAnimation() {
        super.startAnimation()
        loadTexture()
    }
    
    public override func stopAnimation() {
        super.stopAnimation()
        // Immediately halt Metal pipeline when screen saver stops
        metalView?.isPaused = true
        isFoldDormant = true
    }
    
    public override func animateOneFrame() {
        // Ultra-fast nano-second read from shared memory/temp state
        guard let state = SharedStateManager.shared.readState() else {
            if !isFoldDormant {
                isFoldDormant = true
                metalView?.isPaused = true
            }
            return
        }
        
        targetTurn = Double(state.turn)
        if state.lidTravel > 0 && state.lidTravel <= 180 {
            metalView?.lidTravel = state.lidTravel
        }
        
        // BATTERY EFFICIENCY ENGINE:
        // When lid is stationary or fully open/closed, sleep GPU completely!
        let delta = abs(targetTurn - currentTurn)
        if delta < 0.0005 {
            if !isFoldDormant {
                isFoldDormant = true
                metalView?.isPaused = true
            }
            return
        }
        
        // Lid is actively moving: wake GPU and render smooth 60fps fold
        if isFoldDormant {
            isFoldDormant = false
            metalView?.isPaused = false
        }
        
        currentTurn += (targetTurn - currentTurn) * 0.3
        if abs(targetTurn - currentTurn) < 0.0005 {
            currentTurn = targetTurn
        }
        
        metalView?.currentTurn = Float(currentTurn)
    }
}
