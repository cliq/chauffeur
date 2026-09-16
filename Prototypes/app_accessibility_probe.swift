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
if request["operation"] as? String == "activateApplication" {
    // After wake, an inactive app can expose no AX windows until activated.
    // Activate this existing PID without opening or relaunching its bundle.
    let app = NSRunningApplication(processIdentifier: Int32(request["pid"] as! Int))
    let activated = app?.activate(options: [.activateAllWindows]) ?? false
    print(activated ? "{\"performed\":true}" : "{\"performed\":false}")
    exit(activated ? 0 : 1)
}
func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
if request["activateBeforeQuery"] as? Bool == true {
    // Activation is asynchronous. After wake or an app switch, wait for this
    // existing process to expose its windows before resolving any controls.
    NSRunningApplication(processIdentifier: Int32(request["pid"] as! Int))?.activate(options: [.activateAllWindows])
    let deadline = Date(timeIntervalSinceNow: 5)
    repeat {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let identifier = request["windowIdentifier"] as? String {
            if windows.contains(where: { attribute($0, kAXIdentifierAttribute) as? String == identifier }) { break }
        } else if !windows.isEmpty { break }
    } while Date() < deadline
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
if request["windowTitle"] != nil || request["windowIdentifier"] != nil {
    let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let matches = windows.filter {
        if let identifier = request["windowIdentifier"] as? String { return attribute($0, kAXIdentifierAttribute) as? String == identifier }
        return attribute($0, kAXTitleAttribute) as? String == request["windowTitle"] as? String
    }
    guard matches.count == 1 else { print("{\"error\":\"Expected one matching window\"}"); exit(1) }
    queue = matches
}
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
func activate(_ element: AXUIElement) {
    NSRunningApplication(processIdentifier: pid)?.activate()
    AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if (request["windowTitle"] != nil || request["windowIdentifier"] != nil), let window = elements.first {
        // SwiftUI text elements may omit AXWindow. A scoped request already
        // identified the owning native window before traversing its children.
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    } else if let window = attribute(element, kAXWindowAttribute), CFGetTypeID(window as CFTypeRef) == AXUIElementGetTypeID() {
        AXUIElementPerformAction(window as! AXUIElement, kAXRaiseAction as CFString)
    }
}
func focus(_ element: AXUIElement) -> Bool {
    activate(element)
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
        // Native file panels can host their controls in a separate macOS
        // process. System routing reaches those controls after verified focus.
        if request["systemKeyboard"] as? Bool == true {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                print("{\"error\":\"Target app lost keyboard focus\"}"); exit(1)
            }
            event.post(tap: .cghidEventTap)
        } else {
            event.postToPid(pid)
        }
    }
    Thread.sleep(forTimeInterval: 0.08)
}
func modifiers() -> CGEventFlags {
    let names = request["modifiers"] as? [String] ?? []
    var flags: CGEventFlags = []
    for (name, flag) in [("command", CGEventFlags.maskCommand), ("shift", .maskShift), ("control", .maskControl), ("option", .maskAlternate)] {
        if names.contains(name) { flags.insert(flag) }
    }
    return flags
}
func pointer(_ element: AXUIElement, operation: String) -> [String: Any] {
    let frame = describe(element)["frame"] as! [String: CGFloat]
    guard let x = request["x"] as? Double, let y = request["y"] as? Double,
          x >= 0, y >= 0, x < frame["width"]!, y < frame["height"]! else { return ["error": "Pointer must be inside the requested control"] }
    let start = CGPoint(x: frame["x"]! + x, y: frame["y"]! + y)
    let flags = modifiers()
    let button: CGMouseButton = operation == "rightClick" ? .right : .left
    // Verify the actual accessible element under the point belongs to the
    // requested PID. Notification Center can own a transparent full-screen
    // window, so a window-rectangle intersection alone is not a hit test.
    var hitOwner: Int?
    func targetIsVisible() -> Bool {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(start.x), Float(start.y), &element) == .success,
              let element else { return false }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success else { return false }
        hitOwner = Int(owner)
        return owner == pid
    }
    for _ in 0..<30 {
        if targetIsVisible() { break }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    guard targetIsVisible() else { return ["error": "Another application covers the requested control", "applicationPID": Int(pid), "hitOwnerPID": hitOwner ?? 0] }
    func post(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
    }
    if operation == "scroll" {
        guard let lines = request["lines"] as? Int32, abs(lines) <= 100 else { return ["error": "Invalid scroll distance"] }
        post(.mouseMoved, at: start)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
        event.location = start; event.flags = flags; event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.1)
    } else if operation == "drag" {
        guard let endX = request["endX"] as? Double, let endY = request["endY"] as? Double,
              endX >= 0, endY >= 0, endX < frame["width"]!, endY < frame["height"]! else { return ["error": "Drag must stay inside the requested control"] }
        let end = CGPoint(x: frame["x"]! + endX, y: frame["y"]! + endY)
        post(.leftMouseDown, at: start)
        post(.leftMouseDragged, at: start)
        for step in 1...10 {
            let fraction = CGFloat(step) / 10
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction))
        }
        post(.leftMouseUp, at: end)
    } else {
        post(.mouseMoved, at: start)
        post(operation == "rightClick" ? .rightMouseDown : .leftMouseDown, at: start)
        post(operation == "rightClick" ? .rightMouseUp : .leftMouseUp, at: start)
    }
    return ["performed": true]
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
        if let value = request["matchValue"] as? String, attribute(element, kAXValueAttribute) as? String != value { return false }
        if let identifier = request["identifier"] as? String { return attribute(element, kAXIdentifierAttribute) as? String == identifier }
        if let placeholder = request["placeholder"] as? String { return attribute(element, kAXPlaceholderValueAttribute) as? String == placeholder }
        if let title = request["title"] as? String {
            return (attribute(element, kAXRoleAttribute) as? String == (request["role"] as? String ?? kAXButtonRole))
                && (attribute(element, kAXTitleAttribute) as? String == title || attribute(element, kAXDescriptionAttribute) as? String == title)
        }
        if let role = request["role"] as? String { return attribute(element, kAXRoleAttribute) as? String == role }
        return false
    }
    if matches.count == 1, let element = matches.first {
        if operation == "press" || operation == "showMenu" {
            if let timeout = request["actionTimeout"] as? Double {
                AXUIElementSetMessagingTimeout(element, Float(timeout))
            }
            let status = AXUIElementPerformAction(element, (operation == "showMenu" ? kAXShowMenuAction : kAXPressAction) as CFString)
            result = ["performed": status == .success, "status": status.rawValue]
        } else if operation == "closeWindow", let button = attribute(element, kAXCloseButtonAttribute), CFGetTypeID(button as CFTypeRef) == AXUIElementGetTypeID() {
            let status = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            result = ["performed": status == .success, "status": status.rawValue]
        } else if operation == "resize", let width = request["width"] as? Double, let height = request["height"] as? Double {
            var size = CGSize(width: width, height: height)
            let status = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
            result = ["performed": status == .success, "status": status.rawValue]
        } else if ["click", "rightClick", "drag", "scroll"].contains(operation) {
            activate(element)
            result = pointer(element, operation: operation!)
        } else if !focus(element) { result = ["error": "The requested control did not receive keyboard focus"] }
        else if operation == "paste" || operation == "copy" {
            result = clipboard(element, paste: operation == "paste" ? request["value"] as? String : nil)
        } else if ["typeText", "insertText"].contains(operation), let value = request["value"] as? String {
            if operation == "typeText" { key(0, flags: .maskCommand) }
            if !value.isEmpty { key(0, text: value) }
            else if operation == "typeText" { key(51) }
            result = ["performed": true]
        } else if operation == "key", let code = request["keyCode"] as? Int {
            key(CGKeyCode(code), flags: modifiers())
            result = ["performed": true]
        } else { result = ["error": "Unsupported operation"] }
    } else { result = ["error": "Expected one matching control", "matches": matches.count] }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
