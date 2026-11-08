import AppKit
import Carbon.HIToolbox

/// A system-wide escape hatch that remains available when the overlay obscures the UI.
@MainActor
final class EmergencyQuitHotKey {

    private static let signature = OSType(0x4F564252) // "OVBR"
    private static let identifier: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    func install() -> Bool {
        guard eventHandler == nil, hotKey == nil else { return hotKey != nil }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerProcPtr = { _, event, _ in
            guard let event else { return noErr }

            var receivedID = EventHotKeyID()
            let result = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &receivedID
            )
            guard result == noErr,
                  receivedID.signature == EmergencyQuitHotKey.signature,
                  receivedID.id == EmergencyQuitHotKey.identifier else {
                return noErr
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApplication.shared.terminate(nil)
                }
            }
            return noErr
        }

        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandler
        )
        guard handlerResult == noErr else {
            Log.system.error("Could not install emergency quit shortcut handler: \(handlerResult)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let hotKeyResult = RegisterEventHotKey(
            UInt32(kVK_Escape), modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKey
        )
        guard hotKeyResult == noErr else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            Log.system.error("Could not register emergency quit shortcut: \(hotKeyResult)")
            return false
        }

        Log.system.info("Emergency quit shortcut registered: Command-Option-Control-Escape")
        return true
    }

    func uninstall() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}