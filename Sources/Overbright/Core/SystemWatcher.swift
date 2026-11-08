import AppKit
import CoreGraphics

/// Listens for every event that has historically knocked one of these apps off the rails
/// and pokes the engine to re-establish itself.
///
/// The recurring bug report across Vivid, BrightIntosh and BrightXDR is some variation of
/// "it stops working after I close the lid / wake it up / unlock it / switch Spaces".
/// The cause is almost always the same: the overlay window survives but the EDR request
/// attached to it does not, so the panel quietly drops back to its SDR ceiling and
/// nothing tells the app. There is no notification for "your EDR grant was revoked", so
/// the only reliable strategy is to treat every state transition as suspect, rebuild, and
/// verify afterwards.
@MainActor
final class SystemWatcher {

    private let engine: BrightnessEngine
    private var heartbeat: Timer?
    private var reconfigRegistered = false

    init(engine: BrightnessEngine) {
        self.engine = engine
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let center = NotificationCenter.default

        // Sleep and wake, both for the machine and for the displays alone.
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.engine.displaysAsleep = true
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.engine.displaysAsleep = false
            self?.recover(after: 1.2, reason: "system wake")
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.engine.displaysAsleep = true
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.engine.displaysAsleep = false
            self?.recover(after: 0.8, reason: "screens wake")
        }

        // Fast user switching leaves windows on a session that is no longer front.
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.engine.screenLocked = true
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.engine.screenLocked = false
            self?.recover(after: 0.6, reason: "session active")
        }

        // Lock screen. There is no public API for this, but these two distributed
        // notifications have been stable for well over a decade.
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.engine.screenLocked = true
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.engine.screenLocked = false
            self?.recover(after: 0.5, reason: "unlock")
        }

        // Screen saver: same shape as locking, different notification.
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { [weak self] in
            self?.engine.screenLocked = true
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { [weak self] in
            self?.engine.screenLocked = false
            self?.recover(after: 0.5, reason: "screensaver end")
        }

        // Resolution change, display arrangement change, colour profile change, lid
        // open/close, dock plug/unplug.
        observe(center, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.recover(after: 0.35, reason: "screen parameters")
        }

        // Switching Spaces and entering Mission Control both reorder the window list.
        // Re-asserting is enough here; a full rebuild would be visible.
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.engine.reassertWindows()
            self?.engine.nudge("space change")
        }

        observe(center, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            self?.engine.nudge("thermal state")
        }
        observe(center, .NSProcessInfoPowerStateDidChange) { [weak self] in
            self?.engine.nudge("power state")
        }

        registerDisplayReconfiguration()
        startHeartbeat()
    }

    // MARK: - Display reconfiguration callback

    /// `didChangeScreenParameters` is coalesced and sometimes arrives late or not at all
    /// during a clamshell transition. The CoreGraphics callback fires earlier and more
    /// reliably, so both are wired up and the recovery path is idempotent.
    private func registerDisplayReconfiguration() {
        guard !reconfigRegistered else { return }

        // A C function pointer cannot capture self, so the recovery entry point is
        // parked in a static trampoline before the callback is installed.
        SystemWatcher.pendingRecovery = { [weak self] delay, reason in
            self?.recover(after: delay, reason: reason)
        }

        let callback: CGDisplayReconfigurationCallBack = { _, flags, _ in
            let interesting: CGDisplayChangeSummaryFlags = [
                .addFlag, .removeFlag, .enabledFlag, .disabledFlag,
                .setModeFlag, .setMainFlag, .desktopShapeChangedFlag
            ]
            guard !flags.intersection(interesting).isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SystemWatcher.pendingRecovery?(0.4, "display reconfiguration")
                }
            }
        }
        CGDisplayRegisterReconfigurationCallback(callback, nil)
        reconfigRegistered = true
    }

    @MainActor private static var pendingRecovery: ((TimeInterval, String) -> Void)?

    // MARK: - Heartbeat

    /// A slow self-check. Two things can silently go wrong without any notification:
    /// another app can order a window above ours, and the EDR grant can lapse while the
    /// overlay stays on screen. Both are cheap to detect and cheap to fix.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        // Built rather than scheduled, then added to .common, so it keeps firing while a
        // menu is open or a window is being resized.
        let timer = Timer(timeInterval: 3.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                BrightnessEngine.shared.reassertWindows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    // MARK: - Recovery

    private var recoveryWork: DispatchWorkItem?

    /// Coalesced rebuild. Several of these notifications arrive in a burst during a
    /// single physical event, and rebuilding once at the end of the burst is both
    /// faster and less visible than rebuilding for each one.
    private func recover(after delay: TimeInterval, reason: String) {
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Log.system.info("Recovering: \(reason, privacy: .public)")
            self.engine.rebuildDisplays()
            self.engine.remountAll()
            self.engine.nudge(reason)
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Helpers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor () -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }
}
