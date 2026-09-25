import CoreGraphics
import Foundation

/// Defines whether the current macOS user session is safe to receive global shortcuts.
enum UserSessionInputPolicy {
    // CGSession has no public constant for this long-standing WindowServer property.
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static var allowsShortcutHandling: Bool {
        guard let properties = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }

        return allowsShortcutHandling(
            sessionProperties: properties,
            isLidClosedWithoutExternalDisplay: DisplayAvailability.isLidClosedWithoutExternalDisplay
        )
    }

    static func allowsShortcutHandling(
        sessionProperties: [String: Any],
        isLidClosedWithoutExternalDisplay: @autoclosure () -> Bool = false
    ) -> Bool {
        guard booleanValue(sessionProperties[kCGSessionOnConsoleKey as String]) == true else {
            return false
        }

        guard booleanValue(sessionProperties[kCGSessionLoginDoneKey as String]) == true else {
            return false
        }

        if booleanValue(sessionProperties[screenIsLockedKey]) == true {
            return false
        }

        // Keep-awake utilities such as Amphetamine lock the screen when the lid closes by posting
        // Control-Command-Q, before the session reports locked. Nobody can press a shortcut on a
        // closed laptop without another display, so a Control shortcut must not start recording.
        if isLidClosedWithoutExternalDisplay() {
            return false
        }

        return true
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }

        return (value as? NSNumber)?.boolValue
    }
}
