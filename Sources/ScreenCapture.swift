import Foundation
import AppKit
import ScreenCaptureKit

public final class ScreenCapture {
    public static let shared = ScreenCapture()
    
    private init() {}
    
    /// Capture the screen or load appropriate image based on settings
    public func fetchImage() async -> CGImage? {
        let settings = AppSettings.shared
        
        switch settings.imageSourceMode {
        case .liveCapture:
            if let img = await captureLiveScreen() {
                return img
            }
            // Fallback if permission not granted or capture failed
            return fetchWallpaperImage() ?? fetchBundledDefaultImage()
            
        case .desktopWallpaper:
            return fetchWallpaperImage() ?? fetchBundledDefaultImage()
            
        case .soloDefault:
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
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }
            
            // Exclude our own app's windows
            let currentAppPID = NSRunningApplication.current.processIdentifier
            let excludedWindows = content.windows.filter { $0.owningApplication?.processID == currentAppPID }
            
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = true
            
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
    
    /// Fallback to the bundled default.png artwork from iphone-solo
    public func fetchBundledDefaultImage() -> CGImage? {
        if let bundleUrl = Bundle.main.url(forResource: "default", withExtension: "png"),
           let img = NSImage(contentsOf: bundleUrl) {
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        
        // Also check relative to executable or Resources folder on Desktop
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
