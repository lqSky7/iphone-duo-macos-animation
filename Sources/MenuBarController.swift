import Foundation
import AppKit
import SwiftUI

public final class MenuBarController: NSObject, NSWindowDelegate {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var angleMenuItem: NSMenuItem?
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
        
        let header = NSMenuItem(title: "macTilt 合盖动画", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        
        let angleItem = NSMenuItem(title: "开合传感器：正在初始化…", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        self.angleMenuItem = angleItem
        menu.addItem(angleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let openSettings = NSMenuItem(title: "控制面板与设置…", action: #selector(openControlPanel), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        
        let welcomeItem = NSMenuItem(title: "使用指南与权限…", action: #selector(openOnboardingWindow), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)
        
        let testToggle = NSMenuItem(title: "开启／关闭动画预览", action: #selector(toggleTestMode), keyEquivalent: "t")
        testToggle.target = self
        menu.addItem(testToggle)
        
        let captureItem = NSMenuItem(title: "重新捕获屏幕快照", action: #selector(recaptureScreen), keyEquivalent: "r")
        captureItem.target = self
        menu.addItem(captureItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出 macTilt", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
        self.statusItem = item
        
        refreshMenuBarTitle()
    }
    
    public func updateAngleDisplay(angle: Double, isConnected: Bool) {
        lastAngle = angle
        lastIsConnected = isConnected
        
        if let button = statusItem?.button {
            if AppSettings.shared.showAngleInMenuBar {
                button.title = " \(Int(angle))°"
            } else {
                button.title = ""
            }
        }
        
        if let angleItem = self.angleMenuItem {
            if isConnected {
                let status = AppSettings.shared.isClosing ? "正在合盖（\(Int(angle))°）" : "空闲（\(Int(angle))°）"
                angleItem.title = "屏幕：\(status)"
            } else {
                angleItem.title = "开合传感器：未连接"
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
        win.title = "macTilt 控制面板"
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
        win.title = "macTilt 使用指南"
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
    
    @objc private func toggleTestMode() {
        let current = AppSettings.shared.isTestModeActive
        AppSettings.shared.isTestModeActive = !current
        if !current {
            AppSettings.shared.testTurnValue = 0.5
        } else {
            AppSettings.shared.testTurnValue = 0.0
        }
    }
    
    @objc private func recaptureScreen() {
        OverlayWindowController.shared.captureScreenAsync()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
