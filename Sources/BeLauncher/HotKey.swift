import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon. It is the only API that works without Accessibility permission,
/// which is exactly why summoning the window asks the user for nothing.
@MainActor
final class HotKey {
    struct Combo: Equatable, Sendable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let label: String

        static let all: [Combo] = [
            Combo(keyCode: 49, carbonModifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘ Space"),
            Combo(keyCode: 49, carbonModifiers: UInt32(optionKey), label: "⌥ Space"),
            Combo(keyCode: 49, carbonModifiers: UInt32(controlKey), label: "⌃ Space"),
            Combo(keyCode: 49, carbonModifiers: UInt32(cmdKey | optionKey), label: "⌥⌘ Space"),
        ]

        static func named(_ label: String) -> Combo { all.first { $0.label == label } ?? all[0] }

        /// Fixed second shortcut: ⌥C jumps straight into clipboard history.
        static let clipboardHistory = Combo(keyCode: 8, carbonModifiers: UInt32(optionKey), label: "⌥ C")

        /// Screen-to-Action: whatever is in front of you, plus what to do with it.
        static let screenAction = Combo(keyCode: 49,
                                        carbonModifiers: UInt32(optionKey | shiftKey),
                                        label: "⌥⇧ Espacio")

        /// Starts/stops a voice note without opening the launcher.
        static let voiceNote = Combo(keyCode: 9,
                                     carbonModifiers: UInt32(cmdKey | optionKey),
                                     label: "⌥⌘ V")

        /// Dictates into the app that was active when the shortcut was pressed.
        static let dictation = Combo(keyCode: 2,
                                     carbonModifiers: UInt32(cmdKey | optionKey),
                                     label: "⌥⌘ D")

        static let callRecording = Combo(keyCode: 8,
                                         carbonModifiers: UInt32(cmdKey | optionKey),
                                         label: "⌥⌘ C")
    }

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var reference: EventHotKeyRef?
    private let identifier: UInt32

    init?(combo: Combo, action: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        identifier = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4243_4E4B), id: identifier) // 'BCNK'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else { return nil }
        self.reference = reference
        Self.handlers[identifier] = action
        _ = hotKeyID
    }

    /// Called explicitly before re-registering; `deinit` on a main-actor class cannot touch
    /// main-actor state, so cleanup is not left to ARC.
    func invalidate() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.handlers[identifier] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, 1, &spec, nil, &eventHandler)
    }

    fileprivate static func fire(_ identifier: UInt32) {
        handlers[identifier]?()
    }
}

private func hotKeyEventCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    // Carbon hot-key events are delivered on the main run loop.
    MainActor.assumeIsolated { HotKey.fire(hotKeyID.id) }
    return noErr
}
