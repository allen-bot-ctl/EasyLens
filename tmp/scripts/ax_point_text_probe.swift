// Read-only experiment: can Accessibility identify text at a screen point?
// Usage: swift tmp/scripts/ax_point_text_probe.swift [top-left-x top-left-y]
// No text content is printed or saved. Defaults to the current pointer.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: CFString) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name, &value)
    return (error, value)
}

func textLength(_ value: CFTypeRef?) -> Int? {
    guard let string = value as? String else { return nil }
    return string.count
}

func axRange(_ value: CFTypeRef?) -> CFRange? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID(),
          AXValueGetType(value as! AXValue) == .cfRange else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range
}

func query(_ element: AXUIElement, _ name: CFString, _ parameter: CFTypeRef) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(element, name, parameter, &value)
    return (error, value)
}

let arguments = CommandLine.arguments
let point: CGPoint
if arguments.count == 3, let x = Double(arguments[1]), let y = Double(arguments[2]) {
    point = CGPoint(x: x, y: y)
} else {
    point = CGEvent(source: nil)?.location ?? .zero
}

print("trusted=\(AXIsProcessTrusted()) point=\(Int(point.x)),\(Int(point.y))")
let system = AXUIElementCreateSystemWide()
var hit: AXUIElement?
let hitError = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
print("hitError=\(hitError.rawValue)")
guard let hit else { exit(0) }

var pid: pid_t = 0
_ = AXUIElementGetPid(hit, &pid)
let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
let (roleError, roleValue) = attribute(hit, kAXRoleAttribute as CFString)
let (valueError, valueValue) = attribute(hit, kAXValueAttribute as CFString)
let (selectedError, selectedValue) = attribute(hit, kAXSelectedTextAttribute as CFString)
let role = (roleValue as? String) ?? "none"
print("app=\(appName) role=\(role) roleError=\(roleError.rawValue) valueError=\(valueError.rawValue) valueLength=\(textLength(valueValue).map(String.init) ?? "none") selectedError=\(selectedError.rawValue) selectedLength=\(textLength(selectedValue).map(String.init) ?? "none")")

var parameterNames: CFArray?
let namesError = AXUIElementCopyParameterizedAttributeNames(hit, &parameterNames)
let names = (parameterNames as? [String]) ?? []
print("parameterNamesError=\(namesError.rawValue) rangeForPosition=\(names.contains(kAXRangeForPositionParameterizedAttribute as String)) stringForRange=\(names.contains(kAXStringForRangeParameterizedAttribute as String))")

var axPoint = point
if let pointValue = AXValueCreate(.cgPoint, &axPoint) {
    let (rangeError, rangeValue) = query(hit, kAXRangeForPositionParameterizedAttribute as CFString, pointValue)
    if let range = axRange(rangeValue) {
        print("rangeForPositionError=\(rangeError.rawValue) location=\(range.location) length=\(range.length)")
        var rangeCopy = range
        if let rangeParameter = AXValueCreate(.cfRange, &rangeCopy) {
            let (stringError, stringValue) = query(hit, kAXStringForRangeParameterizedAttribute as CFString, rangeParameter)
            print("stringForRangeError=\(stringError.rawValue) length=\(textLength(stringValue).map(String.init) ?? "none")")
        }
    } else {
        print("rangeForPositionError=\(rangeError.rawValue) location=none length=none")
    }
}
