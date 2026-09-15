import AppKit
import ApplicationServices
import Foundation

// Drives only the explicitly supplied fixture PID using existing OS permission.
// No permission prompts or settings changes. Keyboard events target that PID
// only, after checking the requested text field has keyboard focus.
guard AXIsProcessTrusted() else {
    print("{\"error\":\"Accessibility access is unavailable\"}"); exit(1)
}
let request = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
let application = AXUIElementCreateApplication(Int32(request["pid"] as! Int))
AXUIElementSetMessagingTimeout(application, 3)
func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func describe(_ element: AXUIElement) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, name) in [("identifier", kAXIdentifierAttribute), ("role", kAXRoleAttribute), ("label", kAXDescriptionAttribute), ("title", kAXTitleAttribute)] {
        result[key] = attribute(element, name) as? String ?? ""
    }
    result["value"] = attribute(element, kAXValueAttribute) as? String ?? ""
    result["enabled"] = attribute(element, kAXEnabledAttribute) as? Bool ?? false
    var point = CGPoint.zero, size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
    if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    result["frame"] = ["x": point.x, "y": point.y, "width": size.width, "height": size.height]
    return result
}
var queue = [application], elements: [AXUIElement] = []
while !queue.isEmpty, elements.count < 1500 {
    let element = queue.removeFirst()
    guard !elements.contains(where: { CFEqual($0, element) }) else { continue }
    elements.append(element)
    queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    if CFEqual(element, application) { queue.append(contentsOf: attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []) }
}
let operation = request["operation"] as? String
var result: Any
if operation == "inspect" { result = elements.map(describe) }
else {
    let matches = elements.filter { element in
        if let identifier = request["identifier"] as? String { return attribute(element, kAXIdentifierAttribute) as? String == identifier }
        if let title = request["title"] as? String {
            return (attribute(element, kAXRoleAttribute) as? String == kAXButtonRole)
                && (attribute(element, kAXTitleAttribute) as? String == title || attribute(element, kAXDescriptionAttribute) as? String == title)
        }
        return false
    }
    if matches.count == 1, let element = matches.first {
        let status: AXError
        if operation == "press" { status = AXUIElementPerformAction(element, kAXPressAction as CFString) }
        else if operation == "typeText", let value = request["value"] as? String {
            NSRunningApplication(processIdentifier: Int32(request["pid"] as! Int))?.activate()
            AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            var hasFocus = false
            for _ in 0..<30 {
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if let current = attribute(application, kAXFocusedUIElementAttribute), CFEqual(current as CFTypeRef, element) {
                    hasFocus = true; break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if hasFocus {
                let source = CGEventSource(stateID: .privateState)
                let pid = Int32(request["pid"] as! Int)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!
                    event.flags = .maskCommand
                    event.postToPid(pid)
                }
                Thread.sleep(forTimeInterval: 0.05)
                let text = Array(value.utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!
                    event.flags = []
                    event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
                    event.postToPid(pid)
                }
                status = .success
            } else { status = .cannotComplete }
        }
        else { status = .actionUnsupported }
        result = ["performed": status == .success, "status": status.rawValue]
    } else { result = ["error": "Expected one matching control", "matches": matches.count] }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
