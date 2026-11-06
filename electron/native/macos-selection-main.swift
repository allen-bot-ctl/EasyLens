// Lightweight command-line bridge used by the Electron main process.
// It shares SelectionReader.swift's live accessibility selection reader so the
// macOS build keeps the exact paragraph/selection semantics of the AppKit app.
import AppKit
import Darwin
import Foundation

private func parsePoint(_ arguments: [String]) -> CGPoint? {
    guard let index = arguments.firstIndex(of: "--point"),
          index + 2 < arguments.count,
          let x = Double(arguments[index + 1]),
          let y = Double(arguments[index + 2]),
          x.isFinite, y.isFinite else {
        return nil
    }
    return CGPoint(x: x, y: y)
}

private func mainScreenMaxY() -> CGFloat {
    // Same primary-display lookup as SelectionReader.axPoint, so the two
    // conversions cancel out exactly before accessibility hit-testing.
    let main = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == CGMainDisplayID()
    }
    return main?.frame.maxY ?? 0
}

private func writeDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
struct MacOSSelectionMain {
    static func main() {
        let arguments = CommandLine.arguments
        let point: CGPoint
        if arguments.contains("--point") {
            guard let electronPoint = parsePoint(arguments) else {
                writeDiagnostic("macos-selection-reader: invalid --point")
                exit(2)
            }
            // Electron reports the cursor in the primary display's top-left
            // space (Y down). readLiveSelection expects AppKit's bottom-left
            // space (Y up), so mirror Y across the primary display's top edge.
            point = CGPoint(x: electronPoint.x,
                            y: mainScreenMaxY() - electronPoint.y)
        } else {
            // AppKit coordinates already; used only for manual invocation.
            point = NSEvent.mouseLocation
        }

        let live = readLiveSelection(at: point)
        guard let text = live.text, !text.isEmpty else {
            writeDiagnostic("macos-selection-reader: no selection (state=\(live.state))")
            exit(1)
        }
        // stdout carries the selected text and nothing else.
        print(text)
    }
}
