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
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        LidSensor.shared.stop()
    }
}
