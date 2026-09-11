import Foundation
import AppKit

/// Ultra-lightweight shared state bridge between macTilt.app and macTilt.saver
public final class SharedStateManager {
    public static let shared = SharedStateManager()
    
    private let stateFileURL = URL(fileURLWithPath: "/tmp/mactilt_state.dat")
    private let cacheImageURL = URL(fileURLWithPath: "/tmp/mactilt_screen.png")
    
    public struct StateData {
        public var magic: UInt32 = 0x4D544C54 // "MTLT"
        public var angle: Float
        public var turn: Float
        public var timestamp: Double
    }
    
    private init() {}
    
    /// Broadcast current physical angle and turn progress to lock screen companion
    public func broadcast(angle: Double, turn: Double) {
        var data = StateData(
            angle: Float(angle),
            turn: Float(turn),
            timestamp: CACurrentMediaTime()
        )
        withUnsafeBytes(of: &data) { rawPtr in
            let buffer = Data(rawPtr)
            try? buffer.write(to: stateFileURL, options: .atomic)
        }
    }
    
    /// Read latest broadcasted angle and turn
    public func readState() -> StateData? {
        guard let buffer = try? Data(contentsOf: stateFileURL),
              buffer.count >= MemoryLayout<StateData>.size else {
            return nil
        }
        return buffer.withUnsafeBytes { rawPtr in
            let state = rawPtr.load(as: StateData.self)
            return state.magic == 0x4D544C54 ? state : nil
        }
    }
    
    /// Save latest screen capture to shared temp file for lock screen companion
    public func saveScreenCache(_ image: CGImage) {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: cacheImageURL, options: .atomic)
        }
    }
    
    /// Load latest screen capture
    public func loadScreenCache() -> CGImage? {
        guard let data = try? Data(contentsOf: cacheImageURL),
              let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return cg
    }
}
