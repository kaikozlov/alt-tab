// Private SkyLight / CoreGraphics APIs for window management.
// These are undocumented but stable across macOS versions.

import Cocoa

let CGS_CONNECTION = CGSMainConnectionID()

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

// MARK: - Connection

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

// MARK: - Window capture (fallback for minimized windows)

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(_ cid: CGSConnectionID, _ windowList: UnsafeMutablePointer<CGWindowID>, _ windowCount: UInt32, _ options: CGSWindowCaptureOptions) -> Unmanaged<CFArray>

// MARK: - Symbolic hotkeys (disable/enable native Cmd+Tab)

enum CGSSymbolicHotKey: Int, CaseIterable {
    case commandTab = 1
    case commandShiftTab = 2
    case commandKeyAboveTab = 6
}

@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int, _ isEnabled: Bool) -> CGError

func setNativeCommandTabEnabled(_ enabled: Bool) {
    for hotkey in CGSSymbolicHotKey.allCases {
        CGSSetSymbolicHotKeyEnabled(hotkey.rawValue, enabled)
    }
}

// MARK: - Window focusing (bring specific window to front)

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: SLPSMode.RawValue) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// MARK: - Spaces

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ wids: CFArray) -> CFArray

@_silgen_name("CGSGetWindowLevel") @discardableResult
func CGSGetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID, _ level: UnsafeMutablePointer<CGWindowLevel>) -> CGError

// MARK: - Process serial number (deprecated in headers but still functional)

@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
