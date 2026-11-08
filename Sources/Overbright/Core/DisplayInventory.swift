import AppKit
import CoreGraphics

/// A display we are willing to act on, plus everything we know about its EDR abilities.
struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let localizedName: String
    let isBuiltIn: Bool

    /// Best-case headroom the panel can ever offer, independent of what is on screen.
    /// 1.0 means "no EDR at all" — boost is impossible, dimming still works.
    let potentialHeadroom: Double

    /// Headroom macOS is granting *right now*, given current content and brightness.
    var currentHeadroom: Double

    /// Reference headroom (macOS 12+). Non-zero on true reference-mode displays.
    let referenceHeadroom: Double

    var supportsBoost: Bool { potentialHeadroom > 1.02 }

    /// True XDR panels advertise a lot of headroom. A plain Retina panel advertises
    /// a little (typically 1.0–2.0 and only when you dim it), which is why boosting a
    /// MacBook Air just steals brightness rather than adding it.
    var isXDRClass: Bool { potentialHeadroom >= 2.0 }

    static func == (a: DisplayInfo, b: DisplayInfo) -> Bool {
        a.id == b.id && a.potentialHeadroom == b.potentialHeadroom
    }
}

enum DisplayInventory {

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(for: $0) == id }
    }

    static func snapshot() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            let builtIn = CGDisplayIsBuiltin(id) != 0

            return DisplayInfo(
                id: id,
                localizedName: screen.localizedName,
                isBuiltIn: builtIn,
                potentialHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                currentHeadroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
                referenceHeadroom: Double(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
            )
        }
    }

    /// The lid being shut is reported as the built-in display disappearing, but there is a
    /// window during the transition where it is still listed. Checking both avoids
    /// re-arming the overlay onto a panel that is about to go away.
    static var isClamshell: Bool {
        let builtInPresent = NSScreen.screens.contains { screen in
            guard let id = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsAsleep(id) == 0
        }
        return !builtInPresent && NSScreen.screens.count > 0
    }
}
