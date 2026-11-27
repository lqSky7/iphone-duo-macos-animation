import Foundation
import AppKit
import SwiftUI
import QuartzCore

public final class MenuBarController: NSObject, NSWindowDelegate, NSMenuDelegate {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var lastAngle: Double = 120.0
    private var lastIsConnected: Bool = false
    // Status item title writes are WindowServer IPC + text shaping on main.
    // At sensor tick rate (up to 120Hz mid-fold) they compete directly with
    // fold frame encoding. Throttle to ~12Hz — the integer degree readout
    // still reads completely live to the eye.
    private var lastTitleUpdateTime: CFTimeInterval = 0
    
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

        let now = CACurrentMediaTime()
        guard now - lastTitleUpdateTime >= 0.08 else { return }
        lastTitleUpdateTime = now

        if let button = statusItem?.button {
            if AppSettings.shared.showAngleInMenuBar && AppSettings.shared.isHardwareSensor {
                // Every title assignment re-renders the status item for each menu bar
                // (the biggest idle cost, measured). Set it only when the text changes,
                // and let the sensor's ±1° dither through at most once a second.
                let shown = Int(angle)
                let jump = abs(shown - lastShownAngle)
                if jump >= 2 || (jump == 1 && now - lastShownTime >= 1.0) {
                    lastShownAngle = shown
                    lastShownTime = now
                    button.title = " \(shown)°"
                }
            } else if !button.title.isEmpty {
                button.title = ""
            }
        }
    }
    private var lastShownAngle: Int = -1000
    private var lastShownTime: CFTimeInterval = 0
    
    public func refreshMenuBarTitle() {
        if let button = statusItem?.button {
            if AppSettings.shared.showAngleInMenuBar && AppSettings.shared.isHardwareSensor {
                lastShownAngle = Int(lastAngle)
                lastShownTime = CACurrentMediaTime()
                button.title = " \(lastShownAngle)°"
            } else {
                lastShownAngle = -1000
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
                title: "Download \(UpdateChecker.shared.latestVersion) Update...",
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
                title: "Preview Opening Animation",
                action: #selector(triggerOpeningPreview),
                keyEquivalent: "p"
            )
            previewItem.target = self
            menu.addItem(previewItem)
            
            let durationSubmenu = NSMenu(title: "Opening Speed")
            let speeds: [(title: String, duration: Double)] = [
                ("Snappy (0.60s)", 0.60),
                ("Natural (0.95s)", 0.95),
                ("Smooth (1.40s)", 1.40),
                ("Cinematic (2.00s)", 2.00)
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
        
        let openSettings = NSMenuItem(title: "Settings...", action: #selector(openSettingsWindow), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit macTilt", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc public func openSettingsWindow() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Content size matches the panel's design size exactly (500 x 650), and
        // the window is resizable so the layout can actually use more room —
        // the root view is flexible, so there is never dead space at the edges.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentMinSize = NSSize(width: 480, height: 560)
        win.center()
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.contentViewController = NSHostingController(rootView: LiquidGlassSettingsView())
        win.isReleasedWhenClosed = false
        
        self.settingsWindow = win
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
            self?.openSettingsWindow()
        }
        
        win.contentViewController = NSHostingController(rootView: onboardingView)
        win.isReleasedWhenClosed = false
        
        self.onboardingWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - NSWindowDelegate
    
    public func windowWillClose(_ notification: Notification) {
        // When the settings window is dismissed, always clear test mode so the
        // fold overlay doesn't stay frozen on screen.
        if AppSettings.shared.isTestModeActive {
            AppSettings.shared.isTestModeActive = false
            AppSettings.shared.testTurnValue = 0.0
        }
        // A closed settings window kept its SwiftUI view alive, re-evaluating the
        // whole panel on every settings change (lid angle ~10×/s). Drop it; the
        // next open builds a fresh one.
        if let win = notification.object as? NSWindow, win === settingsWindow {
            DispatchQueue.main.async { [weak self] in
                win.contentViewController = nil
                self?.settingsWindow = nil
            }
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
