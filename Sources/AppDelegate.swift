import Foundation
import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as accessory app with menu bar item, but allow control panel window activation
        NSApp.setActivationPolicy(.accessory)
        
        // Initialize subsystems
        _ = MenuBarController.shared
        _ = OverlayWindowController.shared
        
        let sensor = LidSensor.shared
        sensor.onTurnUpdate = { turn, angle in
            OverlayWindowController.shared.update(turn: turn, angle: angle)
            MenuBarController.shared.updateAngleDisplay(angle: angle, isConnected: AppSettings.shared.isSensorConnected)
        }
        sensor.start()
        
        // On first launch, open the Apple HCI Onboarding window; otherwise open the control panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !AppSettings.shared.hasCompletedOnboarding {
                MenuBarController.shared.openOnboardingWindow()
            } else {
                MenuBarController.shared.openControlPanel()
            }
        }
        
        // Setup updates and check in background
        UpdateChecker.shared.requestNotificationPermission()
        if AppSettings.shared.automaticallyCheckForUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                UpdateChecker.shared.checkForUpdates(userInitiated: false)
            }
        }
    }
    
    /// Escape hatch for the "Hide Menu Bar Icon" setting: with no status item and
    /// an .accessory activation policy there is no Dock icon either, so
    /// relaunching macTilt from Finder is the only way back. Reopen the control
    /// panel in that case instead of activating to nothing.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MenuBarController.shared.openControlPanel()
        }
        return true
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        LidSensor.shared.stop()
    }
}
