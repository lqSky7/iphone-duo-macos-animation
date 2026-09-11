import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

public final class ScreenCapture {
    public static let shared = ScreenCapture()

    // P0-3: WindowServer enumeration (SCShareableContent) IPCs + walks every
    // window — up to seconds with many windows. Cache content + filter with
    // short TTLs; force-refresh on miss. Never on the fold critical path twice.
    private var cachedContent: (content: SCShareableContent, date: Date)?
    private var cachedFilter: (filter: SCContentFilter, displayID: CGDirectDisplayID, width: Int, height: Int, date: Date)?
    private static let contentCacheTTL: TimeInterval = 5.0
    // Filters hold the window list from creation — windows born later
    // (including our own overlay on show) are NOT excluded. Short TTL +
    // explicit invalidation on show, not a failed capture.
    private static let filterCacheTTL: TimeInterval = 1.5

    private init() {}

    public func invalidateFilterCache() {
        cachedFilter = nil
    }

    public func invalidateCaches() {
        cachedContent = nil
        cachedFilter = nil
    }

    /// Prefer the built-in panel in multi-display sets: mirror sets report
    /// several displays and `first` is arbitrary. Falls back to first.
    static func preferredDisplay(from content: SCShareableContent) -> SCDisplay? {
        if let builtin = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) {
            return builtin
        }
        return content.displays.first
    }
    
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
    
    /// Capture the screen or load appropriate image based on settings.
    /// scaleFactor is a multiplier on the panel's backing scale. It MUST stay
    /// at 1.0 (native Retina): FoldShaders.metal derives its blur radius from
    /// `uiPixel = 2.0 / imageSize`, which assumes exactly 2 texels per point.
    /// A half-res capture both softens the fold-start frame (upscaled 2x, so
    /// text reads as blocky) and doubles the blur radius in point terms, which
    /// starves the Vogel disc and shows the tap pattern as pixelation.
    public func fetchImage(scaleFactor: CGFloat = 1.0) async -> CGImage? {
        let settings = AppSettings.shared
        
        switch settings.imageSourceMode {
        case .liveCapture:
            // Hot path: fast synchronous preflight only. The full async probe
            // (enumeration + test capture) runs on didBecomeActive via
            // AppSettings.refreshPermissions — never per fold frame.
            if hasPermission(), let img = await captureLiveScreen(scaleFactor: scaleFactor) {
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
    
    /// Live display capture using ScreenCaptureKit.
    /// One-shot SCScreenshotManager (never a streaming SCStream): no stream
    /// setup/teardown, no queueDepth memory.
    /// scaleFactor 1.0 = native Retina, which the fold shader requires.
    public func captureLiveScreen(scaleFactor: CGFloat = 1.0) async -> CGImage? {
        do {
            let content = try await freshShareableContent()
            guard let display = Self.preferredDisplay(from: content) else { return nil }

            let filter = cachedDisplayFilter(for: display, in: content)
            let config = SCStreamConfiguration()
            // NSScreen is main-thread-only; this runs on background tasks.
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
            let targetW = max(2, Int(Double(display.width) * Double(scale) * Double(scaleFactor)))
            let targetH = max(2, Int(Double(display.height) * Double(scale) * Double(scaleFactor)))
            config.width = targetW
            config.height = targetH
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("[ScreenCapture] ScreenCaptureKit error: \(error)")
            // Stale cache (display reconfigured) — drop it so next call re-enumerates.
            cachedContent = nil
            cachedFilter = nil
            return nil
        }
    }

    private func freshShareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent,
           Date().timeIntervalSince(cached.date) < Self.contentCacheTTL {
            return cached.content
        }
        let content: SCShareableContent
        if #available(macOS 14.4, *) {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } else {
            content = try await SCShareableContent.current
        }
        cachedContent = (content, Date())
        return content
    }

    private func cachedDisplayFilter(for display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        // Mode changes reuse displayIDs with new geometry — key by all three.
        if let cached = cachedFilter,
           cached.displayID == display.displayID,
           cached.width == display.width,
           cached.height == display.height,
           Date().timeIntervalSince(cached.date) < Self.filterCacheTTL {
            return cached.filter
        }
        // Exclude our own app's windows so the overlay never captures itself.
        let currentAppPID = NSRunningApplication.current.processIdentifier
        let excludedWindows = content.windows.filter { $0.owningApplication?.processID == currentAppPID }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        cachedFilter = (filter, display.displayID, display.width, display.height, Date())
        return filter
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
        
        // Bundle-relative fallbacks only (portable across machines)
        if let classBundleUrl = Bundle(for: ScreenCapture.self).url(forResource: "default", withExtension: "png"),
           let img = NSImage(contentsOf: classBundleUrl) {
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        let fallbackPaths = [
            Bundle.main.bundlePath + "/Contents/Resources/default.png",
            Bundle.main.bundlePath + "/Resources/default.png",
            CommandLine.arguments[0].split(separator: "/").dropLast().joined(separator: "/") + "/Resources/default.png"
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
