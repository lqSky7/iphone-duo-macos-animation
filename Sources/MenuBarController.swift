import Foundation
import AppKit
import SwiftUI

public final class MenuBarController: NSObject, NSWindowDelegate, NSMenuDelegate {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var lastAngle: Double = 120.0
    private var lastIsConnected: Bool = false
    
    public override init() {
        super.init()
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "macTilt")
            button.imagePosition = .imageLeading
            button.title = ""
        }
        
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.statusItem = item
        
        applyMenuBarIconVisibility()
        refreshMenuBarTitle()
    }
    
    /// Single source of truth for status item visibility. Called at setup and
    /// from AppSettings.hideMenuBarIcon.didSet.
    public func applyMenuBarIconVisibility() {
        statusItem?.isVisible = !AppSettings.shared.hideMenuBarIcon
    }
    
    public func updateAngleDisplay(angle: Double, isConnected: Bool) {
        lastAngle = angle
        lastIsConnected = isConnected
        
        if let button = statusItem?.button {
            if AppSettings.shared.showAngleInMenuBar && AppSettings.shared.isHardwareSensor {
                button.title = " \(Int(angle))°"
            } else {
                button.title = ""
            }
        }
    }
    
    public func refreshMenuBarTitle() {
        if let button = statusItem?.button {
            if AppSettings.shared.showAngleInMenuBar && AppSettings.shared.isHardwareSensor {
                button.title = " \(Int(lastAngle))°"
            } else {
                button.title = ""
            }
        }
    }
    
    // MARK: - NSMenuDelegate
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        let isHW = AppSettings.shared.isHardwareSensor
        
        // 1. Header
        let headerTitle = isHW ? "macTilt Lid Tilt Animation" : "macTilt Clamshell Animation"
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        
        // 2. Update Available (if any)
        if UpdateChecker.shared.updateAvailable {
            let updateItem = NSMenuItem(
                title: "✨ Download \(UpdateChecker.shared.latestVersion) Update...",
                action: #selector(openLatestRelease),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
        }
        
        // 3. Status indicator
        let statusTitle: String
        if lastIsConnected {
            if isHW {
                let status = AppSettings.shared.isClosing ? "Closing (\(Int(lastAngle))°)" : "Open (\(Int(lastAngle))°)"
                statusTitle = "Sensor: \(status)"
            } else {
                statusTitle = "Mode: Clamshell Opening Animation"
            }
        } else {
            statusTitle = "Lid Sensor: Initializing..."
        }
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        // 4. Clamshell Opening Animation Controls — ONLY IF NO LAS SENSOR DETECTED!
        if !isHW {
            menu.addItem(NSMenuItem.separator())
            
            let previewItem = NSMenuItem(
                title: "▶ Preview Opening Animation",
                action: #selector(triggerOpeningPreview),
                keyEquivalent: "p"
            )
            previewItem.target = self
            menu.addItem(previewItem)
            
            let durationSubmenu = NSMenu(title: "Opening Speed")
            let speeds: [(title: String, duration: Double)] = [
                ("⚡ Snappy (0.60s)", 0.60),
                ("✨ Natural (0.95s)", 0.95),
                ("🎬 Smooth (1.40s)", 1.40),
                ("🍿 Cinematic (2.00s)", 2.00)
            ]
            
            let currentDur = AppSettings.shared.clamshellOpeningDuration
            for (title, dur) in speeds {
                let subItem = NSMenuItem(title: title, action: #selector(setSpeedPreset(_:)), keyEquivalent: "")
                subItem.target = self
                subItem.representedObject = dur
                if abs(currentDur - dur) < 0.08 {
                    subItem.state = .on
                }
                durationSubmenu.addItem(subItem)
            }
            
            let durationMenuItem = NSMenuItem(
                title: "Opening Speed (\(String(format: "%.2fs", currentDur)))",
                action: nil,
                keyEquivalent: ""
            )
            durationMenuItem.submenu = durationSubmenu
            menu.addItem(durationMenuItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)
        
        let openSettings = NSMenuItem(title: "Control Panel & Settings...", action: #selector(openControlPanel), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit macTilt", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc public func openControlPanel() {
        if let existing = controlPanelWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.center()
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.contentViewController = NSHostingController(rootView: LiquidGlassControlPanel())
        win.isReleasedWhenClosed = false
        
        self.controlPanelWindow = win
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc public func openOnboardingWindow() {
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.center()
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        
        let onboardingView = OnboardingView { [weak self, weak win] in
            win?.close()
            self?.openControlPanel()
        }
        
        win.contentViewController = NSHostingController(rootView: onboardingView)
        win.isReleasedWhenClosed = false
        
        self.onboardingWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - NSWindowDelegate
    
    public func windowWillClose(_ notification: Notification) {
        // When the control panel is dismissed, always clear test mode so the
        // fold overlay doesn't stay frozen on screen.
        if AppSettings.shared.isTestModeActive {
            AppSettings.shared.isTestModeActive = false
            AppSettings.shared.testTurnValue = 0.0
        }
    }
    
    public func refreshUpdateMenuState() {
        DispatchQueue.main.async { [weak self] in
            guard let menu = self?.statusItem?.menu else { return }
            self?.menuNeedsUpdate(menu)
        }
    }
    
    @objc private func setSpeedPreset(_ sender: NSMenuItem) {
        if let dur = sender.representedObject as? Double {
            AppSettings.shared.clamshellOpeningDuration = dur
            LidSensor.shared.triggerOpeningPreview()
        }
    }
    
    @objc private func triggerOpeningPreview() {
        LidSensor.shared.triggerOpeningPreview()
    }
    
    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates(userInitiated: true)
    }

    @objc private func openLatestRelease() {
        UpdateChecker.shared.openLatestRelease()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
