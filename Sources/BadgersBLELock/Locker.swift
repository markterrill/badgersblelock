import Foundation
import CoreGraphics
import IOKit

enum Locker {
    /// `SACLockScreenImmediate` lives in a private framework, so we resolve it at
    /// runtime rather than linking it — if Apple ever removes it we degrade to
    /// display sleep instead of failing to launch.
    private static let sacLockScreenImmediate: (@convention(c) () -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let sym = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
    }()

    static var canLockDirectly: Bool { sacLockScreenImmediate != nil }

    static func sleepDisplay() {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard entry != 0 else { return }
        IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanTrue)
        IOObjectRelease(entry)
    }

    /// Locks the screen. Falls back to sleeping the display, which locks only if
    /// "Require password immediately after sleep" is enabled in System Settings.
    @discardableResult
    static func lock() -> Bool {
        if let lockFn = sacLockScreenImmediate, lockFn() == 0 {
            sleepDisplay()
            return true
        }
        sleepDisplay()
        return false
    }

    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dict["CGSSessionScreenIsLocked"] as? Int
        else { return false }
        return locked == 1
    }
}
