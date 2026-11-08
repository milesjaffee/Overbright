import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max.circle",
                                     accessibilityDescription: "Overbright")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ControlPanel(engine: BrightnessEngine.shared))

        Settings.shared.$position
            .combineLatest(Settings.shared.$enabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        refreshIcon()
    }

    private func refreshIcon() {
        let s = Settings.shared
        let symbol: String
        if !s.enabled {
            symbol = "sun.max.circle"
        } else if s.position > 0.02 {
            symbol = "sun.max.circle.fill"
        } else if s.position < -0.02 {
            symbol = "moon.circle.fill"
        } else {
            symbol = "sun.max.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Overbright")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click is a fast toggle, matching what people expect from these apps.
            Settings.shared.enabled.toggle()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
