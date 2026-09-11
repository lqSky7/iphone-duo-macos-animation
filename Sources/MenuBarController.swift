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
        
        item.menu = makeMenu()
        self.statusItem = item
        
        refreshMenuBarTitle()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        
        let header = NSMenuItem(title: tr("macTilt 合盖动画", "macTilt Lid Animation"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        
        let angleItem = NSMenuItem(title: tr("开合传感器：正在初始化…", "Lid sensor: initializing…"), action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        self.angleMenuItem = angleItem
        menu.addItem(angleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let openSettings = NSMenuItem(title: tr("控制面板与设置…", "Control Panel & Settings…"), action: #selector(openControlPanel), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        
        let welcomeItem = NSMenuItem(title: tr("使用指南与权限…", "Guide & Permissions…"), action: #selector(openOnboardingWindow), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)
        
        let testToggle = NSMenuItem(title: tr("开启／关闭动画预览", "Toggle Animation Preview"), action: #selector(toggleTestMode), keyEquivalent: "t")
        testToggle.target = self
        menu.addItem(testToggle)
        
        let captureItem = NSMenuItem(title: tr("重新捕获屏幕快照", "Recapture Screen Snapshot"), action: #selector(recaptureScreen), keyEquivalent: "r")
        captureItem.target = self
        menu.addItem(captureItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: tr("退出 macTilt", "Quit macTilt"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        return menu
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
                let status = AppSettings.shared.isClosing ? tr("正在合盖（\(Int(angle))°）", "Closing (\(Int(angle))°)") : tr("空闲（\(Int(angle))°）", "Idle (\(Int(angle))°)")
                angleItem.title = tr("屏幕：\(status)", "Lid: \(status)")
            } else {
                angleItem.title = tr("开合传感器：未连接", "Lid sensor: not connected")
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

    /// Rebuilds the menu and window titles in the current language.
    public func refreshLocalizedText() {
        statusItem?.menu = makeMenu()
        controlPanelWindow?.title = controlPanelTitle
        onboardingWindow?.title = onboardingTitle
        updateAngleDisplay(angle: lastAngle, isConnected: lastIsConnected)
    }

    private var controlPanelTitle: String { tr("macTilt 控制面板", "macTilt Control Panel") }
    private var onboardingTitle: String { tr("macTilt 使用指南", "macTilt Guide") }
    
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
        win.title = controlPanelTitle
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
        win.title = onboardingTitle
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
