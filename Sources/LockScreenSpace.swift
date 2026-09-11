import AppKit
import Darwin

// SkyLight ABI and space technique based on Lakr233/SkyLightWindow (MIT).
// See Resources/ThirdParty/SkyLightWindow-LICENSE.txt.
final class LockScreenSpace {
    static let shared = LockScreenSpace()
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias Show = @convention(c) (Int32, CFArray) -> Int32
    private typealias Add = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private var copySpaces: CopySpaces?
    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var setLevel: SetLevel?
    private var show: Show?
    private var add: Add?

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let c = dlsym(handle, "SLSMainConnectionID"),
              let s = dlsym(handle, "SLSSpaceCreate"),
              let l = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let v = dlsym(handle, "SLSShowSpaces"),
              let a = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            NSLog("[macTilt] 锁屏显示接口不可用")
            return
        }
        connection = unsafeBitCast(c, to: Connection.self)()
        space = unsafeBitCast(s, to: Create.self)(connection, 1, 0)
        guard space > 0 else { return }
        setLevel = unsafeBitCast(l, to: SetLevel.self)
        show = unsafeBitCast(v, to: Show.self)
        add = unsafeBitCast(a, to: Add.self)
        if let symbol = dlsym(handle, "SLSCopySpacesForWindows") {
            copySpaces = unsafeBitCast(symbol, to: CopySpaces.self)
        }
    }

    @discardableResult
    func configure(_ window: NSWindow, enabled: Bool) -> Bool {
        guard space > 0, let setLevel, let show, let add else { return false }
        let levelResult = setLevel(connection, space, enabled ? 400 : 0)
        _ = add(connection, space, [window.windowNumber] as CFArray, 7)
        _ = show(connection, [space] as CFArray)
        // Some SkyLight entry points are void on newer systems; verify membership,
        // rather than interpreting an undefined return register as CGError.
        let spaces = copySpaces?(connection, 7, [window.windowNumber] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
        let success = spaces.contains { $0.int32Value == space }
        NSLog("[macTilt] 锁屏显示空间：%@，目标 %d，窗口 %d，实际 %@", success ? "已验证归属" : "归属查询未确认", space, Int32(window.windowNumber), String(describing: spaces))
        return levelResult == 0
    }
}
