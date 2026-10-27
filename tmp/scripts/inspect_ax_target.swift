// Diagnostic for real applications. Prints AX structure and selection lengths, never text.
// swiftc tmp/scripts/inspect_ax_target.swift -o tmp/scripts/.build/inspect-ax -framework AppKit -framework ApplicationServices
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

func parameter(_ element: AXUIElement, _ key: String, _ value: CFTypeRef) -> CFTypeRef? {
    var output: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(element, key as CFString,
                                                       value, &output) == .success ? output : nil
}

func rangeString(_ value: CFTypeRef?) -> String {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return "nil" }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return "invalid" }
    return "\(range.location):\(range.length)"
}

func rectString(_ value: CFTypeRef?) -> String {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return "nil" }
    var rect = CGRect.zero
    guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return "invalid" }
    return "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
}

func geometry(_ element: AXUIElement, _ point: CGPoint) -> String {
    var point = point
    guard let position = AXValueCreate(.cgPoint, &point) else { return "no-point" }
    let native = attribute(element, kAXSelectedTextRangeAttribute as String)
    let pointed = parameter(element, "AXRangeForPosition", position)
    var result = "selectedRange=\(rangeString(native)) pointRange=\(rangeString(pointed))"
    if let native {
        result += " selectedBounds=\(rectString(parameter(element, "AXBoundsForRange", native)))"
    }
    if let pointed {
        result += " pointBounds=\(rectString(parameter(element, "AXBoundsForRange", pointed)))"
    }
    if let marker = attribute(element, "AXSelectedTextMarkerRange"),
       CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() {
        let start = AXTextMarkerRangeCopyStartMarker(marker as! AXTextMarkerRange)
        let end = AXTextMarkerRangeCopyEndMarker(marker as! AXTextMarkerRange)
        let startIndex = parameter(element, "AXIndexForTextMarker", start) as? NSNumber
        let endIndex = parameter(element, "AXIndexForTextMarker", end) as? NSNumber
        let startLine = parameter(element, "AXLineForTextMarker", start) as? NSNumber
        let endLine = parameter(element, "AXLineForTextMarker", end) as? NSNumber
        let pointerMarker = parameter(element, "AXTextMarkerForPosition", position)
        let pointerIndex = pointerMarker.flatMap {
            parameter(element, "AXIndexForTextMarker", $0) as? NSNumber
        }
        result += " marker=\(startIndex?.intValue ?? -1)..\(endIndex?.intValue ?? -1) lines=\(startLine?.intValue ?? -1)..\(endLine?.intValue ?? -1) pointMarker=\(pointerMarker != nil) pointIndex=\(pointerIndex?.intValue ?? -1)"
        result += " markerBounds=\(rectString(parameter(element, "AXBoundsForTextMarkerRange", marker)))"
        if let startIndex {
            let m1 = parameter(element, "AXTextMarkerForIndex", startIndex)
            let m2 = parameter(element, "AXTextMarkerForIndex", NSNumber(value: startIndex.intValue + 1))
            result += " indexMarkers=\(m1 != nil),\(m2 != nil)"
            if let m1, let m2,
               CFGetTypeID(m1) == AXTextMarkerGetTypeID(),
               CFGetTypeID(m2) == AXTextMarkerGetTypeID() {
                let charRange = AXTextMarkerRangeCreate(nil, m1 as! AXTextMarker,
                                                        m2 as! AXTextMarker)
                result += " firstBounds=\(rectString(parameter(element, "AXBoundsForTextMarkerRange", charRange)))"
            }
            let line = parameter(element, "AXLineTextMarkerRangeForTextMarker", start)
            result += " lineMarker=\(line != nil)"
            if let line { result += " lineBounds=\(rectString(parameter(element, "AXBoundsForTextMarkerRange", line)))" }
        }
        if let startLine, let endLine, endLine.intValue - startLine.intValue <= 6 {
            for line in startLine.intValue...endLine.intValue {
                if let lineRange = parameter(element, "AXTextMarkerRangeForLine", NSNumber(value: line)) {
                    result += " L\(line)=\(rectString(parameter(element, "AXBoundsForTextMarkerRange", lineRange)))"
                } else { result += " L\(line)=nil" }
            }
        }
        var previous = start as CFTypeRef
        for step in 0..<4 {
            guard let next = parameter(element, "AXNextLineEndTextMarkerForTextMarker", previous),
                  CFGetTypeID(next) == AXTextMarkerGetTypeID(),
                  CFGetTypeID(previous) == AXTextMarkerGetTypeID() else {
                result += " nextLine\(step)=nil"
                break
            }
            let index = parameter(element, "AXIndexForTextMarker", next) as? NSNumber
            let fragment = AXTextMarkerRangeCreate(nil, previous as! AXTextMarker,
                                                   next as! AXTextMarker)
            result += " frag\(step)=\(index?.intValue ?? -1):\(rectString(parameter(element, "AXBoundsForTextMarkerRange", fragment)))"
            previous = next
        }
        if let pointerMarker, let pointerIndex {
            let next = parameter(element, "AXTextMarkerForIndex", NSNumber(value: pointerIndex.intValue + 1))
            if let next, CFGetTypeID(next) == AXTextMarkerGetTypeID(),
               CFGetTypeID(pointerMarker) == AXTextMarkerGetTypeID() {
                let charRange = AXTextMarkerRangeCreate(nil, pointerMarker as! AXTextMarker,
                                                        next as! AXTextMarker)
                result += " charBounds=\(rectString(parameter(element, "AXBoundsForTextMarkerRange", charRange)))"
            } else { result += " nextMarker=nil" }
        }
    }
    return result
}

func describe(_ label: String, _ start: AXUIElement?, _ point: CGPoint?) {
    guard var element = start else { print("\(label): missing"); return }
    for depth in 0..<8 {
        AXUIElementSetMessagingTimeout(element, 0.25)
        let role = attribute(element, kAXRoleAttribute as String) as? String ?? "?"
        let selected = attribute(element, kAXSelectedTextAttribute as String) as? String
        let marker = attribute(element, "AXSelectedTextMarkerRange")
        let selectedRange = attribute(element, kAXSelectedTextRangeAttribute as String)
        let range = selectedRange != nil ? "yes" : "no"
        let markerState = marker != nil ? "yes" : "no"
        print("\(label)[\(depth)] role=\(role) selectedLength=\(selected?.count ?? 0) range=\(range) marker=\(markerState)")
        if (selected?.isEmpty == false), let point {
            print("  \(geometry(element, point))")
        }
        guard let parent = attribute(element, kAXParentAttribute as String) else { break }
        element = parent as! AXUIElement
    }
}

let args = CommandLine.arguments
let targetPID = args.count >= 5 && args[1] == "--pid" ? Int32(args[2]) : nil
let pointStart = targetPID == nil ? 1 : 3
guard let app = NSWorkspace.shared.frontmostApplication else { exit(1) }
let pid = targetPID ?? app.processIdentifier
print("app=\(app.localizedName ?? "?") targetPID=\(pid)")
let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 0.25)
let focused = attribute(root, kAXFocusedUIElementAttribute as String)
let point = args.count >= pointStart + 2 ?
    CGPoint(x: Double(args[pointStart]) ?? 0,
            y: Double(args[pointStart + 1]) ?? 0) : nil
describe("focused", focused.map { $0 as! AXUIElement }, point)
if args.count >= pointStart + 2,
   let x = Float(args[pointStart]), let y = Float(args[pointStart + 1]) {
    var hit: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(root, x, y, &hit)
    print("hitError=\(error.rawValue)")
    describe("point", hit, CGPoint(x: CGFloat(x), y: CGFloat(y)))
}
