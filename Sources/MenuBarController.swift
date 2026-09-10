import Foundation
import AppKit
import SwiftUI

public final class MenuBarController: NSObject {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private var angleMenuItem: NSMenuItem?
    
    public override init() {
        super.init()
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "iPhone Duo")
            button.imagePosition = .imageLeading
            button.title = " --°"
        }
        
        let menu = NSMenu()
        
        let header = NSMenuItem(title: "iPhone Duo Clamshell Animation", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        
        let angleItem = NSMenuItem(title: "Lid Sensor: Initializing...", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        self.angleMenuItem = angleItem
        menu.addItem(angleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let openSettings = NSMenuItem(title: "Control Panel & Settings...", action: #selector(openControlPanel), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        
        let testToggle = NSMenuItem(title: "Toggle Test Preview Slider", action: #selector(toggleTestMode), keyEquivalent: "t")
        testToggle.target = self
        menu.addItem(testToggle)
        
        let captureItem = NSMenuItem(title: "Re-capture Screen Snapshot", action: #selector(recaptureScreen), keyEquivalent: "r")
        captureItem.target = self
        menu.addItem(captureItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit iPhone Duo", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
        self.statusItem = item
    }
    
    public func updateAngleDisplay(angle: Double, isConnected: Bool) {
        if let button = statusItem?.button {
            button.title = " \(Int(angle))°"
        }
        if let angleItem = self.angleMenuItem {
            if isConnected {
                let status = AppSettings.shared.isClosing ? "Closing (\(Int(angle))°)" : "Idle (\(Int(angle))°)"
                angleItem.title = "Lid: \(status)"
            } else {
                angleItem.title = "Lid Sensor: Disconnected"
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
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
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func toggleTestMode() {
        let current = AppSettings.shared.isTestModeActive
        AppSettings.shared.isTestModeActive = !current
        if !current {
            AppSettings.shared.testTurnValue = 0.5
        }
    }
    
    @objc private func recaptureScreen() {
        OverlayWindowController.shared.captureScreenAsync()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
