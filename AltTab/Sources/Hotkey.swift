import Cocoa
import Carbon.HIToolbox

/// Global hotkey handling: intercepts Cmd+Tab, detects Cmd release, handles Tab/arrow cycling.
final class Hotkey {
    static let shared = Hotkey()

    var onActivate: (() -> Void)?       // Cmd+Tab pressed (first time)
    var onCycleForward: (() -> Void)?   // Tab pressed while panel is open
    var onCycleBackward: (() -> Void)?  // Shift+Tab while panel is open
    var onConfirm: (() -> Void)?        // Cmd released → focus selected window
    var onCancel: (() -> Void)?         // Escape pressed → dismiss
    var onQuit: (() -> Void)?           // Q pressed while panel open → quit selected app
    var onClose: (() -> Void)?          // W pressed while panel open → close selected window

    private var hotkeyRef: EventHotKeyRef?
    private var shiftHotkeyRef: EventHotKeyRef?
    private var pressedHandler: EventHandlerRef?
    private var releasedHandler: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var localMonitor: Any?
    private(set) var panelIsOpen = false

    private static let signature = OSType(0x414C5454) // "ALTT"
    private static let hotkeyId = UInt32(1)
    private static let shiftHotkeyId = UInt32(2)

    private init() {}

    // MARK: - Public

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
        if open {
            installLocalMonitor()
        } else {
            removeLocalMonitor()
        }
    }

    // MARK: - Carbon hotkeys (Cmd+Tab and Cmd+Shift+Tab)

    private func registerCarbonHotkeys() {
        let target = GetEventDispatcherTarget()

        // Pressed handler
        var pressedType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(target, { (_, event, _) -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                if id.id == Hotkey.hotkeyId {
                    if Hotkey.shared.panelIsOpen {
                        Hotkey.shared.onCycleForward?()
                    } else {
                        Hotkey.shared.onActivate?()
                    }
                } else if id.id == Hotkey.shiftHotkeyId {
                    if Hotkey.shared.panelIsOpen {
                        Hotkey.shared.onCycleBackward?()
                    }
                }
            }
            return noErr
        }, 1, &pressedType, nil, &pressedHandler)

        // Register Cmd+Tab
        let cmdTabId = EventHotKeyID(signature: Hotkey.signature, id: Hotkey.hotkeyId)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey), cmdTabId, target, 0, &hotkeyRef)

        // Register Cmd+Shift+Tab
        let cmdShiftTabId = EventHotKeyID(signature: Hotkey.signature, id: Hotkey.shiftHotkeyId)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey | shiftKey), cmdShiftTabId, target, 0, &shiftHotkeyRef)
    }

    private func unregisterCarbonHotkeys() {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        if let ref = shiftHotkeyRef { UnregisterEventHotKey(ref); shiftHotkeyRef = nil }
        if let handler = pressedHandler { RemoveEventHandler(handler); pressedHandler = nil }
        if let handler = releasedHandler { RemoveEventHandler(handler); releasedHandler = nil }
    }

    // MARK: - CGEventTap (detect Cmd release via flagsChanged)

    private func installCGEventTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_, _, cgEvent, _) -> Unmanaged<CGEvent>? in
                let flags = cgEvent.flags
                let cmdDown = flags.contains(.maskCommand)

                if !cmdDown && Hotkey.shared.panelIsOpen {
                    DispatchQueue.main.async {
                        Hotkey.shared.onConfirm?()
                    }
                }

                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: nil
        )

        if let tap = eventTap {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func removeCGEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    // MARK: - Local key monitor (while panel is open)

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panelIsOpen else { return event }

            switch Int(event.keyCode) {
            case kVK_Tab:
                if event.modifierFlags.contains(.shift) {
                    self.onCycleBackward?()
                } else {
                    self.onCycleForward?()
                }
                return nil // absorb

            case kVK_Escape:
                self.onCancel?()
                return nil

            case kVK_ANSI_Q:
                self.onQuit?()
                return nil

            case kVK_ANSI_W:
                self.onClose?()
                return nil

            case kVK_LeftArrow:
                self.onCycleBackward?()
                return nil

            case kVK_RightArrow:
                self.onCycleForward?()
                return nil

            default:
                return event
            }
        }
    }

    private func removeLocalMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
