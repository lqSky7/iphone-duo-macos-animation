import Foundation
import AppKit
import SwiftUI

public final class MenuBarController: NSObject, NSWindowDelegate {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var angleMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
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
        
        let header = NSMenuItem(title: "macTilt Clamshell Animation", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        
        let updateItem = NSMenuItem(title: "✨ Update Available", action: #selector(openLatestRelease), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        self.updateMenuItem = updateItem
        menu.addItem(updateItem)
        
        let angleItem = NSMenuItem(title: "Lid Sensor: Initializing...", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        self.angleMenuItem = angleItem
        menu.addItem(angleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Deliberately minimal: the control panel owns every other action
        // (permissions, re-capture, interactive preview, update check). Keeping
        // duplicates here made the menu a second, staler copy of the panel.
        let openSettings = NSMenuItem(title: "Control Panel & Settings...", action: #selector(openControlPanel), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit macTilt", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
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
            if AppSettings.shared.showAngleInMenuBar {
                if AppSettings.shared.isHardwareSensor {
                    button.title = " \(Int(angle))°"
                } else {
                    button.title = ""
                }
            } else {
                button.title = ""
            }
        }
        
        if let angleItem = self.angleMenuItem {
            if isConnected {
                if AppSettings.shared.isHardwareSensor {
                    let status = AppSettings.shared.isClosing ? "Closing (\(Int(angle))°)" : "Open (\(Int(angle))°)"
                    angleItem.title = "Sensor: \(status)"
                } else {
                    angleItem.title = "Mode: Clamshell Auto-Animation"
                }
            } else {
                angleItem.title = "Lid Sensor: Disconnected"
            }
        }
    }
    
    public func refreshMenuBarTitle() {
        if let button = statusItem?.button {
            if AppSettings.shared.showAngleInMenuBar {
                button.title = " \(Int(lastAngle))°"
            } else {
                button.title = ""
            }
        }
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
        DispatchQueue.main.async {
            if UpdateChecker.shared.updateAvailable {
                self.updateMenuItem?.title = "✨ Download \(UpdateChecker.shared.latestVersion) Update..."
                self.updateMenuItem?.isHidden = false
            } else {
                self.updateMenuItem?.isHidden = true
            }
        }
    }
    
    @objc private func openLatestRelease() {
        UpdateChecker.shared.openLatestRelease()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
