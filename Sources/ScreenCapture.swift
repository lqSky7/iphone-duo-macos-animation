import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

public final class ScreenCapture {
    public static let shared = ScreenCapture()
    
    private init() {}
    
    /// Fast synchronous preflight
    public func hasPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }
    
    /// Comprehensive async verification using both CoreGraphics and ScreenCaptureKit
    public func verifyPermissionAsync() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        
        // Probe via ScreenCaptureKit: if we can list external windows, permission is active
        do {
            let content: SCShareableContent
            if #available(macOS 14.4, *) {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } else {
                content = try await SCShareableContent.current
            }
            let currentPID = NSRunningApplication.current.processIdentifier
            let otherWindows = content.windows.filter { $0.owningApplication?.processID != currentPID }
            if !otherWindows.isEmpty {
                return true
            }
            if !content.displays.isEmpty {
                // Test capturing a small 1x1 test frame
                let filter = SCContentFilter(display: content.displays[0], excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 2
                config.height = 2
                if let _ = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    return true
                }
            }
        } catch {
            return false
        }
        
        return false
    }
    
    /// Request screen recording permission from macOS
    @discardableResult
    public func requestPermission() -> Bool {
        return CGRequestScreenCaptureAccess()
    }
    
    /// Open System Settings directly to Privacy & Security -> Screen Recording
    public func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Relaunch application to pick up updated TCC permissions
    public func relaunchApp() {
        let appUrl = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        
        NSWorkspace.shared.openApplication(at: appUrl, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
    
    /// Capture the screen or load appropriate image based on settings
    public func fetchImage() async -> CGImage? {
        let settings = AppSettings.shared
        
        switch settings.imageSourceMode {
        case .liveCapture:
            if await verifyPermissionAsync(), let img = await captureLiveScreen() {
                return img
            }
            // Fallback if permission not granted or capture failed
            return fetchWallpaperImage() ?? fetchBundledDefaultImage()
            
        case .desktopWallpaper:
            return fetchWallpaperImage() ?? fetchBundledDefaultImage()
            
        case .bundledArtwork:
            return fetchBundledDefaultImage()
            
        case .customImage:
            if !settings.customImagePath.isEmpty,
               let image = NSImage(contentsOfFile: settings.customImagePath),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cgImage
            }
            return fetchBundledDefaultImage()
        }
    }
    
    /// Live display capture using ScreenCaptureKit
    public func captureLiveScreen() async -> CGImage? {
        do {
            let content: SCShareableContent
            if #available(macOS 14.4, *) {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } else {
                content = try await SCShareableContent.current
            }
            guard let display = content.displays.first else { return nil }
            
            // Exclude our own app's windows
            let currentAppPID = NSRunningApplication.current.processIdentifier
            let excludedWindows = content.windows.filter { $0.owningApplication?.processID == currentAppPID }
            
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            config.width = Int(Double(display.width) * scale)
            config.height = Int(Double(display.height) * scale)
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("[ScreenCapture] ScreenCaptureKit error: \(error)")
            return nil
        }
    }
    
    /// Get user's current desktop wallpaper
    public func fetchWallpaperImage() -> CGImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    
    /// Fallback to the bundled default.png artwork
    public func fetchBundledDefaultImage() -> CGImage? {
        if let bundleUrl = Bundle.main.url(forResource: "default", withExtension: "png"),
           let img = NSImage(contentsOf: bundleUrl) {
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        
        let fallbackPaths = [
            Bundle.main.bundlePath + "/Contents/Resources/default.png",
            Bundle.main.bundlePath + "/Resources/default.png",
            CommandLine.arguments[0].split(separator: "/").dropLast().joined(separator: "/") + "/Resources/default.png",
            "/Users/ca5/Desktop/iphone-duo-macos-animation/Resources/default.png"
        ]
        for path in fallbackPaths {
            if let img = NSImage(contentsOfFile: path),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cg
            }
        }
        return nil
    }
}
