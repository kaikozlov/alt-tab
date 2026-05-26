import ApplicationServices

/// AXUIElement is a CFType, so Swift conditional casts warn/error even when the value
/// may be another accessibility object. Check the CFTypeID first, then bridge.
func safeAXElement(from value: AnyObject?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}
