import CoreGraphics
import Testing
@testable import Voice

struct UserSessionInputPolicyTests {
    private let activeSession: [String: Any] = [
        kCGSessionOnConsoleKey as String: true,
        kCGSessionLoginDoneKey as String: true,
    ]

    @Test func allowsShortcutsInAnActiveSession() {
        #expect(UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: activeSession))
    }

    @Test func ignoresShortcutsWhileTheScreenIsLocked() {
        var session = activeSession
        session["CGSSessionScreenIsLocked"] = true

        #expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: session))
    }

    @Test func ignoresShortcutsWhenTheLidIsClosedWithoutAnotherDisplay() {
        // Amphetamine posts Control-Command-Q here, before the session reports locked.
        #expect(
            !UserSessionInputPolicy.allowsShortcutHandling(
                sessionProperties: activeSession,
                isLidClosedWithoutExternalDisplay: true
            ))
    }

    @Test func checksTheLidOnlyForAnActiveSession() {
        var lidChecked = false
        var session = activeSession
        session["CGSSessionScreenIsLocked"] = true

        _ = UserSessionInputPolicy.allowsShortcutHandling(
            sessionProperties: session,
            isLidClosedWithoutExternalDisplay: {
                lidChecked = true
                return false
            }()
        )

        #expect(!lidChecked)
    }
}
