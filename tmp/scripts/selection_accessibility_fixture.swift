// Manual end-to-end fixture for highlighted text, without copying to the clipboard.
// Build: swiftc tmp/scripts/selection_accessibility_fixture.swift -o tmp/scripts/.build/selection-fixture -framework AppKit -framework WebKit
// Run:   tmp/scripts/.build/selection-fixture [--web]
import AppKit
import WebKit

private let paragraph = "No worries, I understood the first time! Sweat and sweet are easy to mix up, especially when typing fast."

private final class SelectionFixture: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 280, y: 320, width: 1100, height: 240),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "EasyLens selection fixture"
        if CommandLine.arguments.contains("--web") {
            let web = WKWebView(frame: window.contentView!.bounds)
            web.navigationDelegate = self
            webView = web
            window.contentView = web
            web.loadHTMLString(
                "<html><body style='background:#151515;color:white;font:25px Arial'>" +
                "<p id='selected'>\(paragraph)</p><p>Thanks again for the kind words.</p>" +
                "</body></html>", baseURL: nil)
        } else {
            let text = NSTextView(frame: window.contentView!.bounds)
            text.string = paragraph + "\nThanks again for the kind words."
            text.font = .systemFont(ofSize: 25)
            window.contentView = text
            window.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: 0, length: (paragraph as NSString).length))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in NSApp.terminate(nil) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.makeFirstResponder(webView)
        webView.evaluateJavaScript(
            "const r=document.createRange();" +
            "r.selectNodeContents(document.getElementById('selected'));" +
            "getSelection().removeAllRanges();getSelection().addRange(r);document.body.focus();")
    }
}

let app = NSApplication.shared
private let delegate = SelectionFixture()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
