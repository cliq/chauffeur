import AppKit
import ApplicationServices
import Foundation

// Drives only the explicitly supplied app PID using existing OS permission.
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
    for (key, name) in [("identifier", kAXIdentifierAttribute), ("role", kAXRoleAttribute), ("label", kAXDescriptionAttribute), ("title", kAXTitleAttribute), ("placeholder", kAXPlaceholderValueAttribute), ("selectedText", kAXSelectedTextAttribute)] {
        result[key] = attribute(element, name) as? String ?? ""
    }
    result["value"] = attribute(element, kAXValueAttribute) as? String ?? ""
    result["enabled"] = attribute(element, kAXEnabledAttribute) as? Bool ?? false
    var actions: CFArray?
    AXUIElementCopyActionNames(element, &actions)
    result["actions"] = actions as? [String] ?? []
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
    // Window controls suffice by default. Avoid collecting system
    // Recent Items or unrelated entries from the app's menu bar.
    if request["includeMenus"] as? Bool != true, attribute(element, kAXRoleAttribute) as? String == kAXMenuBarRole { continue }
    elements.append(element)
    queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    if CFEqual(element, application) { queue.append(contentsOf: attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []) }
}
let operation = request["operation"] as? String
let pid = Int32(request["pid"] as! Int)
func focus(_ element: AXUIElement) -> Bool {
    NSRunningApplication(processIdentifier: pid)?.activate()
    AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    for _ in 0..<30 {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let current = attribute(application, kAXFocusedUIElementAttribute), CFEqual(current as CFTypeRef, element) { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}
func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        event.flags = flags
        if let text {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: 0.08)
}
// Clipboard contents are held in memory only, then restored if the fixture's
// value is still current. Concurrent clipboard changes are left alone.
func clipboard(_ element: AXUIElement, paste: String?) -> [String: Any] {
    let board = NSPasteboard.general
    let previous = (board.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    }
    let expected = paste ?? (attribute(element, kAXSelectedTextAttribute) as? String ?? "")
    guard !expected.isEmpty else { return ["error": "The fixture has no selected text"] }
    if let paste { board.clearContents(); board.setString(paste, forType: .string) }
    let changeCount = board.changeCount
    key(paste == nil ? 8 : 9, flags: .maskCommand)
    if paste == nil {
        for _ in 0..<20 {
            if board.changeCount != changeCount { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    let copied = board.string(forType: .string)
    let unchanged = paste != nil ? board.changeCount == changeCount : board.changeCount != changeCount
    guard unchanged, copied == expected else { return ["error": "Clipboard did not contain the fixture's expected value"] }
    board.clearContents()
    if !previous.isEmpty { board.writeObjects(previous) }
    return ["performed": true, "text": expected]
}
var result: Any
if operation == "inspect" { result = elements.map(describe) }
else {
    let matches = elements.filter { element in
        if let identifier = request["identifier"] as? String { return attribute(element, kAXIdentifierAttribute) as? String == identifier }
        if let placeholder = request["placeholder"] as? String { return attribute(element, kAXPlaceholderValueAttribute) as? String == placeholder }
        if let title = request["title"] as? String {
            return (attribute(element, kAXRoleAttribute) as? String == (request["role"] as? String ?? kAXButtonRole))
                && (attribute(element, kAXTitleAttribute) as? String == title || attribute(element, kAXDescriptionAttribute) as? String == title)
        }
        return false
    }
    if matches.count == 1, let element = matches.first {
        if operation == "press" {
            let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
            result = ["performed": status == .success, "status": status.rawValue]
        } else if operation == "closeWindow", let button = attribute(element, kAXCloseButtonAttribute), CFGetTypeID(button as CFTypeRef) == AXUIElementGetTypeID() {
            let status = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            result = ["performed": status == .success, "status": status.rawValue]
        } else if operation == "resize", let width = request["width"] as? Double, let height = request["height"] as? Double {
            var size = CGSize(width: width, height: height)
            let status = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
            result = ["performed": status == .success, "status": status.rawValue]
        } else if !focus(element) { result = ["error": "The requested control did not receive keyboard focus"] }
        else if operation == "paste" || operation == "copy" {
            result = clipboard(element, paste: operation == "paste" ? request["value"] as? String : nil)
        } else if ["typeText", "insertText"].contains(operation), let value = request["value"] as? String {
            if operation == "typeText" { key(0, flags: .maskCommand) }
            if !value.isEmpty { key(0, text: value) }
            else if operation == "typeText" { key(51) }
            result = ["performed": true]
        } else if operation == "key", let code = request["keyCode"] as? Int {
            let names = request["modifiers"] as? [String] ?? []
            var flags: CGEventFlags = []
            for (name, flag) in [("command", CGEventFlags.maskCommand), ("shift", .maskShift), ("control", .maskControl), ("option", .maskAlternate)] {
                if names.contains(name) { flags.insert(flag) }
            }
            key(CGKeyCode(code), flags: flags)
            result = ["performed": true]
        } else { result = ["error": "Unsupported operation"] }
    } else { result = ["error": "Expected one matching control", "matches": matches.count] }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
