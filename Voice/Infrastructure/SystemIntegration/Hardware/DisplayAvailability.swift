import CoreGraphics
import IOKit

/// Whether the Mac can be in use: a closed lid with no other display means its screen and keyboard
/// are out of reach and it is about to sleep. Clamshell mode with an external display still counts
/// as in use.
enum DisplayAvailability {
    private static let rootDomain = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOPMrootDomain")
    )

    static var isLidClosedWithoutExternalDisplay: Bool {
        isLidClosed && !hasExternalDisplay
    }

    /// Read on each call, so it is current even before a clamshell notification arrives.
    static var isLidClosed: Bool {
        guard rootDomain != 0,
            let value = IORegistryEntryCreateCFProperty(
                rootDomain,
                "AppleClamshellState" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? Bool
        else {
            return false
        }
        return value
    }

    /// Includes sleeping and mirrored displays, and Sidecar or AirPlay displays.
    static var hasExternalDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return false
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return false
        }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}
