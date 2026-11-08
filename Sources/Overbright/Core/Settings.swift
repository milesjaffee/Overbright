import Foundation
import Combine

/// One value drives the whole app: `position`, from -1 (as dark as we can make it)
/// through 0 (exactly what macOS gives you) to +1 (as bright as the panel allows).
final class Settings: ObservableObject {

    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var position: Double {
        didSet { defaults.set(position, forKey: Keys.position) }
    }

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }

    /// How many stops below the macOS floor the dark half of the slider reaches.
    /// 3 stops is one eighth of minimum brightness, which is about as far as an
    /// LCD/mini-LED panel can go before dithering artefacts become obvious.
    @Published var dimStops: Double {
        didSet { defaults.set(dimStops, forKey: Keys.dimStops) }
    }

    /// Fraction of the granted headroom left unused. Boosting right up to the reported
    /// limit is what makes highlights clip and makes the picture wobble whenever the
    /// system trims headroom for thermal reasons.
    @Published var headroomReserve: Double {
        didSet { defaults.set(headroomReserve, forKey: Keys.headroomReserve) }
    }

    /// Fraction of the panel's peak headroom we are willing to use across the whole
    /// screen. Apple rates the Liquid Retina XDR at 1600 nits peak but 1000 nits
    /// sustained full-field; 1000/1600 = 0.625. Asking for the peak figure produces a
    /// screen that is briefly dazzling and then visibly sags as the panel protects
    /// itself, which reads as pulsing.
    @Published var sustainedFraction: Double {
        didSet { defaults.set(sustainedFraction, forKey: Keys.sustainedFraction) }
    }

    @Published var suspendOnLowPower: Bool {
        didSet { defaults.set(suspendOnLowPower, forKey: Keys.suspendOnLowPower) }
    }

    @Published var suspendWhenHot: Bool {
        didSet { defaults.set(suspendWhenHot, forKey: Keys.suspendWhenHot) }
    }

    @Published var boostExternalDisplays: Bool {
        didSet { defaults.set(boostExternalDisplays, forKey: Keys.boostExternal) }
    }

    /// Seconds of full-rate polling after any system event before dropping back to the
    /// low-power poll rate.
    @Published var settleWindow: Double {
        didSet { defaults.set(settleWindow, forKey: Keys.settleWindow) }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    private enum Keys {
        static let position = "position"
        static let enabled = "enabled"
        static let dimStops = "dimStops"
        static let headroomReserve = "headroomReserve"
        static let sustainedFraction = "sustainedFraction"
        static let suspendOnLowPower = "suspendOnLowPower"
        static let suspendWhenHot = "suspendWhenHot"
        static let boostExternal = "boostExternalDisplays"
        static let settleWindow = "settleWindow"
        static let launchAtLogin = "launchAtLogin"
    }

    private init() {
        defaults.register(defaults: [
            Keys.position: 0.0,
            Keys.enabled: true,
            Keys.dimStops: 3.0,
            Keys.headroomReserve: 0.12,
            Keys.sustainedFraction: 0.625,
            Keys.suspendOnLowPower: false,
            Keys.suspendWhenHot: true,
            Keys.boostExternal: true,
            Keys.settleWindow: 4.0,
            Keys.launchAtLogin: false
        ])

        position = defaults.double(forKey: Keys.position)
        enabled = defaults.bool(forKey: Keys.enabled)
        dimStops = defaults.double(forKey: Keys.dimStops)
        headroomReserve = defaults.double(forKey: Keys.headroomReserve)
        sustainedFraction = defaults.double(forKey: Keys.sustainedFraction)
        suspendOnLowPower = defaults.bool(forKey: Keys.suspendOnLowPower)
        suspendWhenHot = defaults.bool(forKey: Keys.suspendWhenHot)
        boostExternalDisplays = defaults.bool(forKey: Keys.boostExternal)
        settleWindow = defaults.double(forKey: Keys.settleWindow)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
    }

    func resetToNative() { position = 0 }
}
