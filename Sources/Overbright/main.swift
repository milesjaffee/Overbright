import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let menuBar = MenuBarController()
    private var watcher: SystemWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menuBar.install()

        let engine = BrightnessEngine.shared
        engine.start()

        let watcher = SystemWatcher(engine: engine)
        watcher.start()
        self.watcher = watcher

        Log.system.info("Overbright started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nothing to undo. The only state this app owns is a pair of windows per
        // display, and windows die with the process — including if it is force quit or
        // crashes. That is the main reason this app does not touch the display gamma
        // table: a process that dies holding a modified gamma ramp can leave the screen
        // in a wrong state with no obvious way for the user to fix it.
        BrightnessEngine.shared.stop()
        Log.system.info("Overbright stopped cleanly")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
