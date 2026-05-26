import Cocoa
import Carbon.HIToolbox

@MainActor
final class Hotkey {
    static let shared = Hotkey()

    var onActivate: (() -> Void)?
    var onCycleForward: (() -> Void)?
    var onCycleBackward: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onQuit: (() -> Void)?
    var onClose: (() -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var shiftHotkeyRef: EventHotKeyRef?
    private var pressedHandler: EventHandlerRef?
    private var releasedHandler: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var localMonitor: Any?
    private(set) var panelIsOpen = false

    private static let signature = OSType(0x414C5454)
    private static let hotkeyId = UInt32(1)
    private static let shiftHotkeyId = UInt32(2)

    private init() {}

    func start() {
        setNativeCommandTabEnabled(false)
        registerCarbonHotkeys()
        installCGEventTap()
    }

    func stop() {
        removeLocalMonitor()
        unregisterCarbonHotkeys()
        removeCGEventTap()
        setNativeCommandTabEnabled(true)
    }

    func setPanelOpen(_ open: Bool) {
        panelIsOpen = open
        if open { installLocalMonitor() } else { removeLocalMonitor() }
    }

    // MARK: - Carbon hotkeys

    private func registerCarbonHotkeys() {
        let target = GetEventDispatcherTarget()
        var pressedType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(target, { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { Hotkey.shared.handlePressedHotkey(id.id) }
            return noErr
        }, 1, &pressedType, nil, &pressedHandler)
        let cmdTab = EventHotKeyID(signature: Hotkey.signature, id: Hotkey.hotkeyId)
        let shiftTab = EventHotKeyID(signature: Hotkey.signature, id: Hotkey.shiftHotkeyId)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey), cmdTab, target, 0, &hotkeyRef)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey | shiftKey), shiftTab, target, 0, &shiftHotkeyRef)
    }

    private func handlePressedHotkey(_ id: UInt32) {
        if id == Hotkey.hotkeyId {
            panelIsOpen ? onCycleForward?() : onActivate?()
        } else if id == Hotkey.shiftHotkeyId, panelIsOpen {
            onCycleBackward?()
        }
    }

    private func unregisterCarbonHotkeys() {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        if let ref = shiftHotkeyRef { UnregisterEventHotKey(ref); shiftHotkeyRef = nil }
        if let handler = pressedHandler { RemoveEventHandler(handler); pressedHandler = nil }
        if let handler = releasedHandler { RemoveEventHandler(handler); releasedHandler = nil }
    }

    // MARK: - CGEventTap

    private func installCGEventTap() {
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue,
            callback: { _, _, event, _ -> Unmanaged<CGEvent>? in
                if !event.flags.contains(.maskCommand), Hotkey.shared.panelIsOpen {
                    DispatchQueue.main.async { Hotkey.shared.onConfirm?() }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        guard let tap = eventTap else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func removeCGEventTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        eventTap = nil
    }

    // MARK: - Local monitor

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panelIsOpen else { return event }
            return self.handleLocalKey(event)
        }
    }

    private func handleLocalKey(_ event: NSEvent) -> NSEvent? {
        switch Int(event.keyCode) {
        case kVK_Tab:
            event.modifierFlags.contains(.shift) ? onCycleBackward?() : onCycleForward?()
        case kVK_Escape:
            onCancel?()
        case kVK_ANSI_Q:
            onQuit?()
        case kVK_ANSI_W:
            onClose?()
        case kVK_LeftArrow:
            onCycleBackward?()
        case kVK_RightArrow:
            onCycleForward?()
        default:
            return event
        }
        return nil
    }

    private func removeLocalMonitor() {
        guard let monitor = localMonitor else { return }
        NSEvent.removeMonitor(monitor)
        localMonitor = nil
    }
}
