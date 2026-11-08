import AppKit
import Combine
import Metal

/// Why the engine is currently holding back, if it is.
enum SuspensionReason: String {
    case none
    case disabled = "Turned off"
    case locked = "Screen locked"
    case asleep = "Display asleep"
    case thermal = "Mac is running hot"
    case lowPower = "Low Power Mode"
    case noDisplays = "No usable display"
}

struct EngineStatus {
    var suspension: SuspensionReason = .none
    var appliedGain: Double = 1.0
    var grantedHeadroom: Double = 1.0
    var usableCeiling: Double = 1.0
    var boostAvailable = false
    var displayName = ""
}

@MainActor
final class BrightnessEngine: ObservableObject {

    static let shared = BrightnessEngine()

    @Published private(set) var status = EngineStatus()

    private let settings = Settings.shared
    private var device: MTLDevice?
    private var overlays: [CGDirectDisplayID: DisplayOverlay] = [:]
    private var displays: [CGDirectDisplayID: DisplayInfo] = [:]

    private var headroomFilter: [CGDirectDisplayID: SampleWindow] = [:]
    private var currentGain: [CGDirectDisplayID: Double] = [:]
    private var ceilingHold: [CGDirectDisplayID: (value: Double, since: Date)] = [:]

    private var timer: DispatchSourceTimer?
    private var lastTick = Date()
    private var fastPollUntil = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    // External state fed in by SystemWatcher.
    var screenLocked = false { didSet { nudge() } }
    var displaysAsleep = false { didSet { nudge() } }

    // MARK: - Tuning

    /// Slew rates in stops per second. Ramping up slowly is comfortable; ramping down
    /// has to be quicker so that a genuine drop in headroom does not leave us clipping,
    /// but still slow enough that the eye reads it as a fade rather than a flicker.
    private let riseStopsPerSecond = 1.6
    private let fallStopsPerSecond = 3.0

    /// A drop in the reported ceiling has to persist before we act on it. macOS dips
    /// the reported headroom briefly during Space switches, window-server restarts and
    /// brightness-key presses, and reacting to those dips is what people see as flicker.
    private let ceilingDropDelay: TimeInterval = 0.45
    private let ceilingDropThreshold = 0.03

    private let fastInterval: TimeInterval = 1.0 / 60.0
    private let idleInterval: TimeInterval = 1.0 / 8.0

    // MARK: - Lifecycle

    private init() {
        device = MTLCreateSystemDefaultDevice()

        settings.$position
            .dropFirst()
            .sink { [weak self] _ in self?.nudge() }
            .store(in: &cancellables)

        settings.$enabled
            .dropFirst()
            .sink { [weak self] _ in self?.nudge() }
            .store(in: &cancellables)
    }

    func start() {
        rebuildDisplays()
        startTimer(interval: fastInterval)
        nudge()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for overlay in overlays.values { overlay.unmount() }
        overlays.removeAll()
    }

    /// Enter the fast polling window. Called whenever anything happened that could have
    /// moved the headroom out from under us.
    func nudge(_ reason: String = "") {
        fastPollUntil = Date().addingTimeInterval(settings.settleWindow)
        if !reason.isEmpty { Log.engine.info("Nudge: \(reason, privacy: .public)") }
        retimeIfNeeded()
    }

    // MARK: - Display set

    /// Tears down and rebuilds every overlay. Deliberately blunt: closing the lid,
    /// plugging in a dock, waking from sleep and switching colour profiles all leave
    /// stale window/layer state behind, and rebuilding is both cheap and reliable.
    func rebuildDisplays() {
        let snapshot = DisplayInventory.snapshot()
        let liveIDs = Set(snapshot.map(\.id))

        for (id, overlay) in overlays where !liveIDs.contains(id) {
            overlay.unmount()
            overlays.removeValue(forKey: id)
            headroomFilter.removeValue(forKey: id)
            currentGain.removeValue(forKey: id)
            ceilingHold.removeValue(forKey: id)
        }

        displays = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })

        guard let device else { return }
        for info in snapshot {
            if overlays[info.id] == nil {
                let overlay = DisplayOverlay(displayID: info.id, device: device)
                overlays[info.id] = overlay
                headroomFilter[info.id] = SampleWindow(capacity: 5, initial: 1.0)
                currentGain[info.id] = 1.0
            }
        }
        nudge("display set rebuilt")
    }

    /// Re-mounts every overlay from scratch without changing the display set. This is
    /// the recovery path for "it just stopped working" after wake or a lid cycle.
    func remountAll() {
        for overlay in overlays.values {
            overlay.unmount()
        }
        for id in currentGain.keys {
            currentGain[id] = 1.0
            headroomFilter[id]?.reset(to: 1.0)
            ceilingHold.removeValue(forKey: id)
        }
        nudge("remount")
    }

    // MARK: - Timing

    private func startTimer(interval: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.resume()
        timer = t
        currentInterval = interval
    }

    private var currentInterval: TimeInterval = 1.0 / 60.0

    private func retimeIfNeeded() {
        let wanted = Date() < fastPollUntil ? fastInterval : idleInterval
        if abs(wanted - currentInterval) > 0.001 {
            startTimer(interval: wanted)
        }
    }

    // MARK: - The loop

    private func tick() {
        let now = Date()
        let dt = min(max(now.timeIntervalSince(lastTick), 0.001), 0.25)
        lastTick = now

        let suspension = currentSuspension()
        if status.suspension != suspension {
            var next = status
            next.suspension = suspension
            publish(next)
        }

        var midTransition = false

        for (id, overlay) in overlays {
            guard let info = displays[id] else { continue }

            // Refresh live headroom for this display.
            var live = info
            if let screen = DisplayInventory.screen(for: id) {
                live.currentHeadroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
                displays[id] = live
            }

            headroomFilter[id, default: SampleWindow(capacity: 5, initial: 1.0)]
                .push(max(1.0, live.currentHeadroom))
            let granted = headroomFilter[id]?.median ?? 1.0

            let ceiling = usableCeiling(for: live, granted: granted, now: now)
            let boostWanted = suspension == .none && settings.position > 0.002 && allowBoost(on: live)
            let target = suspension == .none
                ? targetGain(position: settings.position, ceiling: boostWanted ? ceiling : 1.0)
                : 1.0

            let applied = slew(from: currentGain[id] ?? 1.0, to: target, dt: dt)
            currentGain[id] = applied
            if abs(log2(applied) - log2(max(target, 0.0001))) > 0.005 { midTransition = true }

            // The overlay has to be on screen before macOS will grant any headroom, and
            // without headroom the computed ceiling is 1.0, which makes the target gain
            // 1.0, which says the overlay is not needed. Mounting whenever a boost is
            // *wanted* rather than whenever a gain is *applied* breaks that circle: the
            // anchor lights, headroom arrives a few frames later, and the gain ramps up.
            let needsOverlay = boostWanted
                || abs(applied - 1.0) > 0.002
                || abs(target - 1.0) > 0.002

            // Stay on the fast poll while waiting for the grant to arrive.
            if boostWanted && ceiling <= 1.02 { midTransition = true }

            if needsOverlay {
                if !overlay.isMounted { overlay.mount() }
                // Hold headroom open only while we actually want a boost. Keeping the
                // panel in an EDR state costs power and heat for nothing otherwise.
                let anchor = boostWanted ? max(1.0, live.potentialHeadroom) : 1.0
                overlay.apply(gain: applied, anchorRequest: anchor)
            } else if overlay.isMounted {
                overlay.apply(gain: 1.0, anchorRequest: 1.0)
                overlay.unmount()
            }

            if id == primaryDisplayID {
                var next = status
                next.appliedGain = applied
                next.grantedHeadroom = granted
                next.usableCeiling = ceiling
                next.boostAvailable = live.supportsBoost
                next.displayName = live.localizedName
                publish(next)
            }
        }

        // Run at display rate only while the gain is actually moving. Once it has
        // settled, an eighth of a second of latency on a headroom change is invisible
        // because the slew limiter turns any change into a ramp anyway — and the idle
        // rate is the difference between a rounding error and a measurable battery cost.
        if midTransition {
            fastPollUntil = max(fastPollUntil, now.addingTimeInterval(0.3))
        }
        retimeIfNeeded()
    }

    /// The engine ticks up to 60 times a second. Republishing an identical struct that
    /// often would redraw the popover for nothing, so changes below the threshold that
    /// the interface can actually display are swallowed.
    private func publish(_ next: EngineStatus) {
        let changed =
            next.suspension != status.suspension ||
            next.boostAvailable != status.boostAvailable ||
            next.displayName != status.displayName ||
            abs(next.appliedGain - status.appliedGain) > 0.004 ||
            abs(next.usableCeiling - status.usableCeiling) > 0.01 ||
            abs(next.grantedHeadroom - status.grantedHeadroom) > 0.01
        if changed { status = next }
    }

    private var primaryDisplayID: CGDirectDisplayID? {
        if let main = NSScreen.main, let id = DisplayInventory.displayID(for: main),
           displays[id] != nil { return id }
        return displays.keys.sorted().first
    }

    // MARK: - Gain maths

    /// Maps the single slider position onto a linear multiplier.
    ///
    /// Both halves are exponential in stops so that a given slider movement produces
    /// roughly the same perceived change wherever you are on the track — a linear
    /// multiplier would make the dark end unusably twitchy.
    func targetGain(position p: Double, ceiling: Double) -> Double {
        if p >= 0 {
            let stops = log2(max(1.0, ceiling))
            return pow(2.0, p * stops)
        } else {
            return pow(2.0, p * settings.dimStops)
        }
    }

    /// The most gain this display can take right now.
    ///
    /// Two caps apply. The first is the headroom macOS is granting. The second, and the
    /// one that matters more in practice, is the panel's *sustained* full-field
    /// luminance rather than its peak. A 14" MacBook Pro will show 1600 nits in a small
    /// highlight but only around 1000 nits across the whole screen, indefinitely. Aiming
    /// at the peak figure gets you a bright screen that visibly sags a few seconds later
    /// as the panel backs off — which is exactly what people describe as pulsing.
    private func usableCeiling(for info: DisplayInfo, granted: Double, now: Date) -> Double {
        let sustainedCap = 1.0 + (max(1.0, info.potentialHeadroom) - 1.0) * settings.sustainedFraction
        let raw = max(1.0, min(granted, sustainedCap) * (1.0 - settings.headroomReserve))

        // Hysteresis: accept increases immediately, but make a decrease prove itself.
        guard let held = ceilingHold[info.id] else {
            ceilingHold[info.id] = (raw, now)
            return raw
        }

        if raw >= held.value - ceilingDropThreshold {
            ceilingHold[info.id] = (max(raw, held.value * 0.999), now)
            return max(raw, held.value * 0.999)
        }

        if now.timeIntervalSince(held.since) >= ceilingDropDelay {
            ceilingHold[info.id] = (raw, now)
            return raw
        }
        return held.value
    }

    private func slew(from current: Double, to target: Double, dt: Double) -> Double {
        guard current > 0, target > 0 else { return target }
        let currentStops = log2(current)
        let targetStops = log2(target)
        let delta = targetStops - currentStops
        let limit = (delta > 0 ? riseStopsPerSecond : fallStopsPerSecond) * dt
        if abs(delta) <= limit { return target }
        return pow(2.0, currentStops + (delta > 0 ? limit : -limit))
    }

    private func allowBoost(on info: DisplayInfo) -> Bool {
        guard info.supportsBoost else { return false }
        if !info.isBuiltIn && !settings.boostExternalDisplays { return false }
        return true
    }

    // MARK: - Suspension

    private func currentSuspension() -> SuspensionReason {
        if !settings.enabled { return .disabled }
        if displays.isEmpty { return .noDisplays }
        if screenLocked { return .locked }
        if displaysAsleep { return .asleep }

        if settings.suspendWhenHot {
            switch ProcessInfo.processInfo.thermalState {
            case .serious, .critical: return .thermal
            default: break
            }
        }
        if settings.suspendOnLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .lowPower
        }
        return .none
    }

    // MARK: - Re-assertion

    /// Puts the overlay windows back on top and back in the right place. Run on a slow
    /// heartbeat and after any system event.
    func reassertWindows() {
        for overlay in overlays.values where overlay.isMounted {
            overlay.reassert()
            overlay.forceRedraw()
        }
    }
}
