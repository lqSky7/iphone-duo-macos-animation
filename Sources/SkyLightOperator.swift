import Foundation
import AppKit

public enum SkyLightSpaceLevel: Int32 {
    case kCGSSpaceAbsoluteLevelDefault = 0
    case kCGSSpaceAbsoluteLevelSetupAssistant = 100
    case kCGSSpaceAbsoluteLevelSecurityAgent = 200
    case kCGSSpaceAbsoluteLevelScreenLock = 300
    case kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock = 400
    case kCGSSpaceAbsoluteLevelBootProgress = 500
    case kCGSSpaceAbsoluteLevelVoiceOver = 600
}

public final class SkyLightOperator {
    public static let shared = SkyLightOperator()
    
    private typealias F_SLSMainConnectionID = @convention(c) () -> Int32
    private typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    
    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var isAvailable: Bool = false
    
    private var SLSMainConnectionID: F_SLSMainConnectionID?
    private var SLSSpaceCreate: F_SLSSpaceCreate?
    private var SLSSpaceSetAbsoluteLevel: F_SLSSpaceSetAbsoluteLevel?
    private var SLSShowSpaces: F_SLSShowSpaces?
    private var SLSSpaceAddWindowsAndRemoveFromSpaces: F_SLSSpaceAddWindowsAndRemoveFromSpaces?
    
    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW) else {
            return
        }
        
        guard let symConnection = dlsym(handle, "SLSMainConnectionID"),
              let symSpaceCreate = dlsym(handle, "SLSSpaceCreate"),
              let symSetLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let symShowSpaces = dlsym(handle, "SLSShowSpaces"),
              let symAddWindows = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            return
        }
        
        SLSMainConnectionID = unsafeBitCast(symConnection, to: F_SLSMainConnectionID.self)
        SLSSpaceCreate = unsafeBitCast(symSpaceCreate, to: F_SLSSpaceCreate.self)
        SLSSpaceSetAbsoluteLevel = unsafeBitCast(symSetLevel, to: F_SLSSpaceSetAbsoluteLevel.self)
        SLSShowSpaces = unsafeBitCast(symShowSpaces, to: F_SLSShowSpaces.self)
        SLSSpaceAddWindowsAndRemoveFromSpaces = unsafeBitCast(symAddWindows, to: F_SLSSpaceAddWindowsAndRemoveFromSpaces.self)
        
        setupSpace()
    }
    
    private func setupSpace() {
        guard let connFn = SLSMainConnectionID,
              let createFn = SLSSpaceCreate,
              let setLevelFn = SLSSpaceSetAbsoluteLevel,
              let showFn = SLSShowSpaces else {
            return
        }
        
        connection = connFn()
        space = createFn(connection, 1, 0)
        
        // 400 is notification center over screen lock, 300 is screen lock
        _ = setLevelFn(connection, space, SkyLightSpaceLevel.kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock.rawValue)
        _ = showFn(connection, [space] as CFArray)
        isAvailable = true
    }
    
    /// Move a window to the topmost lock-screen SkyLight space.
    /// Guard first: a never-shown window (number 0) must not keep the
    /// reserved level with no space membership. A failed space move resets
    /// to .screenSaver so the window degrades honestly instead of sitting at
    /// Int32.max-2 outside any space.
    @discardableResult
    public func delegateWindow(_ window: NSWindow) -> Bool {
        guard isAvailable, let addFn = SLSSpaceAddWindowsAndRemoveFromSpaces else {
            return false
        }

        let windowNumber = window.windowNumber
        guard windowNumber > 0 else { return false }

        // Configure AppKit properties
        window.canBecomeVisibleWithoutLogin = true
        window.level = .init(rawValue: Int(Int32.max - 2))

        let status = addFn(connection, space, [windowNumber] as CFArray, 7)
        if status != 0 {
            window.level = .screenSaver
            return false
        }
        return true
    }
}
