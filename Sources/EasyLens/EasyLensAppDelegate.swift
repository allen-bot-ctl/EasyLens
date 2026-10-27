// Migrated from the validated macOS lens prototype.
import AppKit
import Carbon.HIToolbox
import Darwin
import ScreenCaptureKit
import SwiftUI

@MainActor
final class EasyLensAppDelegate: NSObject, NSApplicationDelegate {
    private let lensSize = CGSize(width: 190, height: 114)
    private let bridge = WordTranslationBridge()
    private let selectionBridge = SelectionTranslationBridge()
    private let languageSetup = TranslationLanguageSetup()
    private var languageSetupWindow: NSWindow?
    private var languageMenuItem: NSMenuItem!
    private var languageSetupTimer: Timer?
    private var hasPresentedLanguageSetup = false
    private var panel: NSPanel!
    private var translationPanel: NSPanel!
    private var contextLabel: NSTextField!
    private var wordLabel: NSTextField!
    private var view: EyeLensView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var nextBreathFrameAt = 0.0
    private var displays: [CGDirectDisplayID: SCDisplay] = [:]
    private var ownWindow: SCWindow?
    private var cardWindow: SCWindow?
    private var hotKeyHandler: EventHandlerRef?
    private var showHotKey: EventHotKeyRef?
    private var escapeHotKey: EventHotKeyRef?
    private var lockFD: Int32 = -1
    private var scanning = false
    private var lastPointer = CGPoint.zero
    private var lastMoveAt = 0.0
    private var generation = 0
    private var inspectedGeneration = -1
    private var nextInspectionAt = 0.0
    private var consecutiveMisses = 0
    private var translationFailures = 0
    private var currentSentence: String?
    private var currentAnchor: String?
    private var currentFocusLine: String?
    private var currentFocusWordIndex: Int?
    private var pendingTranslationKey: String?
    private var translationCache: [String: FocusedTranslation] = [:]
    private var pasteboardChangeCount = 0
    private var nextPasteboardPollAt = 0.0
    private var clipboardHint: String?
    private var clipboardHintDeadline = 0.0
    private var clipboardHintMisses = 0
    private var activeSelectionHint: String?
    private var activeSelectionSource = "none"
    private var selectionHitGeneration = -1
    private var selectionHitPointer = CGPoint.zero
    private var selectionRequestID = 0
    private var pendingSelectionText: String?
    private var selectionCache: [String: String] = [:]
    private var showingSelectionCard = false
    private var fixedPoint: CGPoint? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--fixed-point"), index + 2 < args.count,
              let x = Double(args[index + 1]), let y = Double(args[index + 2]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask)[0]
            .appendingPathComponent("EasyLens", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: supportDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            print("ERROR cannot create EasyLens support directory: \(error)")
            NSApp.terminate(nil)
            return
        }
        let lockPath = supportDirectory.appendingPathComponent("EasyLens.lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fd >= 0, Darwin.fcntl(fd, F_SETLK, &lock) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            print("ERROR another EasyLens is running; quit it from the EL menu first")
            NSApp.terminate(nil)
            return
        }
        lockFD = fd
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        lastPointer = pointer
        lastMoveAt = uptime()
        panel = NSPanel(contentRect: frame(around: pointer), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let lensBounds = CGRect(origin: .zero, size: lensSize)
        let container = NSView(frame: lensBounds)
        let frost = NSVisualEffectView(frame: lensBounds)
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.alphaValue = 0.58
        frost.wantsLayer = true
        let eyeRect = lensBounds.insetBy(dx: 3, dy: 3)
        let clearCenter = CGRect(x: eyeRect.midX - eyeRect.height * 0.60,
                                 y: eyeRect.midY - eyeRect.height * 0.40,
                                 width: eyeRect.height * 1.20,
                                 height: eyeRect.height * 0.80)
        let frostPath = CGMutablePath()
        frostPath.addPath(EyeLensView.eyePath(in: eyeRect).cgPath)
        frostPath.addEllipse(in: clearCenter)
        let frostMask = CAShapeLayer()
        frostMask.frame = lensBounds
        frostMask.path = frostPath
        frostMask.fillRule = .evenOdd
        frost.layer?.mask = frostMask
        container.addSubview(frost)
        view = EyeLensView(frame: lensBounds)
        container.addSubview(view)
        panel.contentView = container
        translationPanel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 100),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        translationPanel.level = .floating
        translationPanel.backgroundColor = .clear
        translationPanel.isOpaque = false
        translationPanel.hasShadow = true
        translationPanel.ignoresMouseEvents = true
        translationPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let card = NSView(frame: CGRect(x: 0, y: 0, width: 380, height: 100))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 0.8
        card.layer?.borderColor = NSColor(calibratedWhite: 0.9, alpha: 0.18).cgColor
        translationPanel.contentView = card
        contextLabel = NSTextField(labelWithString: "")
        contextLabel.font = .systemFont(ofSize: 16, weight: .medium)
        contextLabel.textColor = .white
        contextLabel.lineBreakMode = .byWordWrapping
        contextLabel.maximumNumberOfLines = 0
        card.addSubview(contextLabel)
        wordLabel = NSTextField(labelWithString: "")
        wordLabel.font = .systemFont(ofSize: 12)
        wordLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        card.addSubview(wordLabel)
        translationPanel.orderOut(nil)
        let taskView = NSHostingView(rootView: TranslationTaskView(bridge: bridge))
        taskView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(taskView)
        let selectedTaskView = NSHostingView(
            rootView: SelectionTranslationTaskView(bridge: selectionBridge))
        selectedTaskView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(selectedTaskView)
        bridge.onResult = { [weak self] generation, result in
            self?.receiveTranslation(generation: generation, result: result)
        }
        selectionBridge.onResult = { [weak self] requestID, result in
            self?.receiveSelectionTranslation(requestID: requestID, result: result)
        }
        panel.orderOut(nil)
        translationPanel.orderOut(nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "EL◉"
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示或隐藏眼睛 (⌃⌥L)",
                              action: #selector(toggle), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let hide = NSMenuItem(title: "隐藏眼睛 (Esc)", action: #selector(hide), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        languageMenuItem = NSMenuItem(title: "检查英中翻译语言…",
                                      action: #selector(showLanguageSetup), keyEquivalent: "")
        languageMenuItem.target = self
        menu.addItem(languageMenuItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 EasyLens", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        installHotKeys()
        print("EASYLENS_READY ⌃⌥L toggles eye lens; Esc hides; EL◉ menu quits")
        print("NO_CLOUD_CALLS screenshots_saved=0")
        fflush(stdout)
        languageSetup.onStatusChange = { [weak self] status in
            self?.languageStatusChanged(status)
        }
        #if DEBUG
        if CommandLine.arguments.contains("--preview-language-setup") {
            languageSetup.previewMissingLanguages()
        } else {
            startLanguageChecks()
        }
        #else
        startLanguageChecks()
        #endif
        if CommandLine.arguments.contains("--show-on-launch") { showLens() }
    }

    private func startLanguageChecks() {
        Task { await languageSetup.refresh() }
        languageSetupTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.languageSetup.isReady else { return }
                await self.languageSetup.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        languageSetupTimer?.invalidate()
        if let showHotKey { UnregisterEventHotKey(showHotKey) }
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if lockFD >= 0 {
            var lock = Darwin.flock()
            lock.l_type = Int16(F_UNLCK)
            lock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(lockFD, F_SETLK, &lock)
            Darwin.close(lockFD)
        }
    }

    private func installHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var identity = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard result == noErr else { return result }
            let probe = Unmanaged<EasyLensAppDelegate>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if identity.id == 1 { probe.toggle() }
                if identity.id == 2 { probe.hide() }
            }
            return noErr
        }, 1, &eventType, opaque, &hotKeyHandler)
        guard status == noErr else { print("ERROR hotkey handler status=\(status)"); return }
        let showID = EventHotKeyID(signature: OSType(0x454C574D), id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey),
                                            showID, GetApplicationEventTarget(), 0, &showHotKey)
        print(registered == noErr ? "WAKE_HOTKEY_REGISTERED=⌃⌥L" :
              "ERROR wake hotkey status=\(registered)")
    }

    private func registerEscape() {
        guard escapeHotKey == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x454C574D), id: 2)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id,
                                         GetApplicationEventTarget(), 0, &escapeHotKey)
        if status != noErr { print("ERROR Escape hotkey status=\(status)") }
    }

    private func releaseEscape() {
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey); self.escapeHotKey = nil }
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : showLens()
    }

    private func showLens() {
        Task { await languageSetup.refresh() }
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        let pasteboard = NSPasteboard.general
        pasteboardChangeCount = pasteboard.changeCount
        nextPasteboardPollAt = 0
        // A sentence may have been copied before the lens was opened. Reuse
        // only multiword text; visual row and local-word checks still gate it.
        clipboardHint = pasteboard.string(forType: .string).flatMap(eligibleClipboardHint)
            .flatMap { clipboardWords($0).count > 1 ? $0 : nil }
        clipboardHintDeadline = uptime() + 5
        clipboardHintMisses = 0
        activeSelectionHint = nil
        activeSelectionSource = "none"
        selectionRequestID += 1
        pendingSelectionText = nil
        showingSelectionCard = false
        lastPointer = pointer
        lastMoveAt = uptime()
        generation += 1
        inspectedGeneration = -1
        nextInspectionAt = 0
        consecutiveMisses = 0
        translationFailures = 0
        currentSentence = nil
        currentAnchor = nil
        currentFocusLine = nil
        currentFocusWordIndex = nil
        pendingTranslationKey = nil
        translationPanel.orderOut(nil)
        view.hasTranslation = false
        nextBreathFrameAt = 0
        panel.setFrame(frame(around: pointer), display: true)
        panel.orderFrontRegardless()
        registerEscape()
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 1.0 / 60.0, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        Task { await prepareCapture() }
        print("LENS_SHOWN preexistingSelectionLength=\(clipboardHint?.count ?? 0)")
        fflush(stdout)
    }

    @objc private func hide() {
        guard panel.isVisible else { return }
        generation += 1
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        translationPanel.orderOut(nil)
        view.hasTranslation = false
        releaseEscape()
        currentSentence = nil
        currentAnchor = nil
        currentFocusLine = nil
        currentFocusWordIndex = nil
        pendingTranslationKey = nil
        clipboardHint = nil
        clipboardHintMisses = 0
        activeSelectionHint = nil
        activeSelectionSource = "none"
        selectionRequestID += 1
        pendingSelectionText = nil
        showingSelectionCard = false
        print("LENS_HIDDEN")
        fflush(stdout)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func languageStatusChanged(_ status: TranslationLanguageSetup.Status) {
        switch status {
        case .checking:
            languageMenuItem.title = "正在检查英中翻译语言…"
        case .ready:
            languageMenuItem.title = "英中翻译语言已就绪"
            inspectedGeneration = -1
            nextInspectionAt = 0
        case .needsDownload:
            languageMenuItem.title = "下载英中翻译语言…"
            if !hasPresentedLanguageSetup {
                hasPresentedLanguageSetup = true
                showLanguageSetup()
            }
        case .downloading:
            languageMenuItem.title = "英中翻译语言下载中…"
        case .unsupported:
            languageMenuItem.title = "英中翻译语言不可用…"
            if !hasPresentedLanguageSetup {
                hasPresentedLanguageSetup = true
                showLanguageSetup()
            }
        case .failed:
            languageMenuItem.title = "英中翻译语言准备失败…"
        }
        print("LANGUAGE_SETUP status=\(status)")
        fflush(stdout)
    }

    @objc private func showLanguageSetup() {
        if languageSetupWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 470, height: 260),
                                  styleMask: [.titled, .closable], backing: .buffered,
                                  defer: false)
            window.title = "EasyLens · 本地翻译"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TranslationLanguageSetupView(
                setup: languageSetup, onDismiss: { [weak self] in
                    self?.languageSetupWindow?.orderOut(nil)
                }))
            window.center()
            languageSetupWindow = window
        }
        languageSetupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    private func frame(around pointer: CGPoint) -> CGRect {
        let screen = screen(at: pointer) ?? NSScreen.main ?? NSScreen.screens[0]
        let x = max(screen.frame.minX, min(pointer.x - lensSize.width / 2,
                                          screen.frame.maxX - lensSize.width))
        let y = max(screen.frame.minY, min(pointer.y - lensSize.height / 2,
                                          screen.frame.maxY - lensSize.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: lensSize)
    }

    private func pollClipboard() {
        guard uptime() >= nextPasteboardPollAt else { return }
        nextPasteboardPollAt = uptime() + 0.2
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = pasteboard.changeCount
        clipboardHint = pasteboard.string(forType: .string).flatMap(eligibleClipboardHint)
        clipboardHintDeadline = uptime() + 5
        clipboardHintMisses = 0
        if !activeSelectionSource.hasPrefix("accessibility") {
            selectionRequestID += 1
            pendingSelectionText = nil
            showingSelectionCard = false
            generation += 1
            inspectedGeneration = -1
            nextInspectionAt = 0
            pendingTranslationKey = nil
            translationPanel.orderOut(nil)
        }
        if let clipboardHint {
            print("CLIPBOARD_HINT accepted length=\(clipboardHint.count)")
        } else {
            print("CLIPBOARD_HINT skipped=non-english-or-unsupported")
        }
        fflush(stdout)
    }

    private func endClipboardHint(reason: String) {
        guard clipboardHint != nil else { return }
        clipboardHint = nil
        clipboardHintMisses = 0
        if !activeSelectionSource.hasPrefix("accessibility") {
            selectionRequestID += 1
            pendingSelectionText = nil
            if showingSelectionCard {
                translationPanel.orderOut(nil)
                showingSelectionCard = false
            }
        }
        print("CLIPBOARD_HINT ended reason=\(reason)")
        fflush(stdout)
    }

    private func showFocusCard(_ chinese: String, anchor: String, basis: String,
                               pointer: CGPoint) {
        guard let screen = screen(at: pointer) else { return }
        showingSelectionCard = false
        let width: CGFloat = min(min(420, screen.frame.width - 12),
            max(180, CGFloat(max(anchor.count + basis.count, chinese.count)) * 15 + 36))
        let contentWidth = width - 32
        let font = NSFont.systemFont(ofSize: 16, weight: .medium)
        let measured = (chinese as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height
        contextLabel.font = font
        contextLabel.stringValue = chinese
        let cellHeight = contextLabel.cell?.cellSize(
            forBounds: CGRect(x: 0, y: 0, width: contentWidth, height: 10000)).height ?? 0
        let textHeight = min(screen.frame.height - 120,
                             max(30, ceil(max(measured, cellHeight)) + 12))
        let height = textHeight + 44
        translationPanel.setContentSize(CGSize(width: width, height: height))
        translationPanel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        wordLabel.stringValue = "\(anchor) · \(basis)"
        wordLabel.frame = CGRect(x: 16, y: height - 30, width: contentWidth, height: 18)
        contextLabel.frame = CGRect(x: 16, y: 10, width: contentWidth, height: textHeight)
        let eyeFrame = panel.frame
        let x = max(screen.frame.minX + 6,
                    min(eyeFrame.midX - width / 2, screen.frame.maxX - width - 6))
        let below = eyeFrame.minY - height - 8
        let y = below >= screen.frame.minY + 6 ? below :
            min(eyeFrame.maxY + 8, screen.frame.maxY - height - 6)
        translationPanel.setFrameOrigin(CGPoint(x: x, y: y))
        translationPanel.orderFrontRegardless()
    }

    private func showSelectionCard(_ chinese: String, pointer: CGPoint) {
        guard let screen = screen(at: pointer) else { return }
        showingSelectionCard = true
        let width: CGFloat = min(420, max(250, screen.frame.width - 12))
        let contentWidth = width - 32
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let measured = (chinese as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height
        contextLabel.font = font
        contextLabel.stringValue = chinese
        let cellHeight = contextLabel.cell?.cellSize(
            forBounds: CGRect(x: 0, y: 0, width: contentWidth, height: 10000)).height ?? 0
        // NSTextField wraps Chinese text differently from NSString's estimate.
        // Leave another line of room so the translated tail remains visible.
        let textHeight = min(screen.frame.height - 120,
                             max(34, ceil(max(measured, cellHeight)) + 22))
        let height = textHeight + 54
        translationPanel.setContentSize(CGSize(width: width, height: height))
        translationPanel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        wordLabel.stringValue = "选区翻译"
        wordLabel.frame = CGRect(x: 16, y: height - 34, width: contentWidth, height: 18)
        contextLabel.frame = CGRect(x: 16, y: 12, width: contentWidth, height: textHeight)
        let eyeFrame = panel.frame
        let x = max(screen.frame.minX + 6,
                    min(eyeFrame.midX - width / 2, screen.frame.maxX - width - 6))
        let below = eyeFrame.minY - height - 8
        let y = below >= screen.frame.minY + 6 ? below :
            min(eyeFrame.maxY + 8, screen.frame.maxY - height - 6)
        translationPanel.setFrameOrigin(CGPoint(x: x, y: y))
        translationPanel.orderFrontRegardless()
    }

    private func receiveSelectionTranslation(requestID: Int,
                                             result: Result<(String, Double), Error>) {
        guard requestID == selectionRequestID, let source = pendingSelectionText else { return }
        pendingSelectionText = nil
        switch result {
        case .success(let (chinese, elapsed)):
            let translated = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else {
                endClipboardHint(reason: "empty-selection-translation")
                inspectedGeneration = -1
                nextInspectionAt = 0
                return
            }
            selectionCache[source] = translated
            let pointer = fixedPoint ?? NSEvent.mouseLocation
            let stillSelected: Bool
            if activeSelectionSource == "accessibility" {
                let live = readLiveSelection(at: pointer)
                stillSelected = live.pointHit && live.text == source
            } else {
                // The pixel hit was checked in the same pointer generation.
                // Movement or a changed AX selection invalidates it; the next
                // scan can use the cache after checking the visible frame.
                let live = readLiveSelection(at: pointer)
                stillSelected = activeSelectionSource == "accessibility-visual" &&
                    selectionHitGeneration == generation && live.text == source &&
                    hypot(pointer.x - selectionHitPointer.x,
                          pointer.y - selectionHitPointer.y) < 3
            }
            if panel.isVisible, activeSelectionHint == source,
               stillSelected {
                showSelectionCard(translated, pointer: fixedPoint ?? NSEvent.mouseLocation)
            }
            print(String(format: "SELECTION_TRANSLATION translatedMs=%.1f resolved=yes sourceLength=%d targetLength=%d cloudCalls=0",
                         elapsed, source.count, translated.count))
        case .failure(let error):
            print("SELECTION_TRANSLATION_ERROR=\(error)")
            Task { await languageSetup.refresh() }
            endClipboardHint(reason: "selection-translation-error")
            inspectedGeneration = -1
            nextInspectionAt = 0
        }
        fflush(stdout)
    }

    private func wordScanFrame(around pointer: CGPoint, on screen: NSScreen) -> CGRect {
        let width = min(CGFloat(1800), screen.frame.width)
        let height = min(CGFloat(220), screen.frame.height)
        let x = max(screen.frame.minX, min(pointer.x - width / 2,
                                          screen.frame.maxX - width))
        let y = max(screen.frame.minY, min(pointer.y - height / 2,
                                          screen.frame.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // Once the center is verified against the live selection, use its complete
    // AX text. The visual fallback verifies location before calling this.
    private func handleSelectedPointHit(_ live: LiveSelection, pointer: CGPoint,
                                        generation current: Int,
                                        sourceName: String = "accessibility") -> Bool {
        guard panel.isVisible, current == generation, live.pointHit else { return false }
        selectionHitGeneration = current
        selectionHitPointer = pointer
        let selected = live.text
        if activeSelectionHint != selected || activeSelectionSource != sourceName {
            selectionRequestID += 1
            pendingSelectionText = nil
            activeSelectionHint = selected
            activeSelectionSource = sourceName
            print("SELECTION_HIT source=\(sourceName) length=\(selected?.count ?? 0) axState=\(live.state)")
        }
        currentSentence = nil
        currentAnchor = nil
        currentFocusLine = nil
        currentFocusWordIndex = nil
        pendingTranslationKey = nil
        view.isReading = false
        inspectedGeneration = -1
        nextInspectionAt = uptime() + (sourceName == "accessibility-visual" ? 0.6 : 0.3)
        if let selected, let cached = selectionCache[selected] {
            showSelectionCard(cached, pointer: pointer)
        } else if let selected, pendingSelectionText != selected {
            guard languageSetup.isReady else { return true }
            translationPanel.orderOut(nil)
            showingSelectionCard = false
            selectionRequestID += 1
            pendingSelectionText = selected
            selectionBridge.translate(selected, requestID: selectionRequestID)
            print("SELECTION_TRANSLATION requested length=\(selected.count) cloudCalls=0")
        } else if selected == nil {
            translationPanel.orderOut(nil)
            showingSelectionCard = false
        }
        fflush(stdout)
        return true
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func prepareCapture() async {
        guard panel.isVisible else { return }
        do {
            try await Task.sleep(nanoseconds: 160_000_000)
            translationPanel.alphaValue = 0.01
            translationPanel.orderFrontRegardless()
            defer {
                translationPanel.orderOut(nil)
                translationPanel.alphaValue = 1
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                onScreenWindowsOnly: false)
            displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
            ownWindow = content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) }
            cardWindow = content.windows.first {
                $0.windowID == CGWindowID(translationPanel.windowNumber)
            }
            guard ownWindow != nil else {
                throw NSError(domain: "EasyLens", code: 1)
            }
            print("CAPTURE_READY displays=\(displays.count) lensWindow=\(panel.windowNumber) cardExcluded=\(cardWindow != nil)")
            fflush(stdout)
        } catch {
            print("CAPTURE_SETUP_ERROR=\(error)")
            fflush(stdout)
        }
    }

    @objc private func tick() {
        guard panel.isVisible else { return }
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        pollClipboard()
        if clipboardHint != nil && uptime() >= clipboardHintDeadline {
            let affectsFocus = !activeSelectionSource.hasPrefix("accessibility")
            endClipboardHint(reason: "expired")
            if affectsFocus {
                generation += 1
                inspectedGeneration = -1
                nextInspectionAt = 0
                pendingTranslationKey = nil
            }
        }
        let nextFrame = frame(around: pointer)
        if panel.frame.origin != nextFrame.origin {
            panel.setFrame(nextFrame, display: true)
        }
        if hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y) >= 3 {
            lastPointer = pointer
            lastMoveAt = uptime()
            generation += 1
            inspectedGeneration = -1
            nextInspectionAt = 0
            consecutiveMisses = 0
            translationFailures = 0
            currentSentence = nil
            currentAnchor = nil
            currentFocusLine = nil
            currentFocusWordIndex = nil
            pendingTranslationKey = nil
            translationPanel.orderOut(nil)
            view.isReading = false
        }
        let now = uptime()
        let success = now - lastMoveAt >= 0.10 && translationPanel.isVisible &&
            translationPanel.alphaValue > 0.5 &&
            (showingSelectionCard || currentAnchor != nil)
        if view.hasTranslation != success { view.hasTranslation = success }
        if now >= nextBreathFrameAt {
            view.needsDisplay = true
            nextBreathFrameAt = now + 1.0 / 24.0
        }
        guard !scanning, uptime() - lastMoveAt >= 0.10,
              inspectedGeneration != generation, uptime() >= nextInspectionAt,
              let screen = screen(at: pointer), let id = displayID(for: screen),
              let display = displays[id], let ownWindow else { return }
        let excluded = [ownWindow] + (cardWindow.map { [$0] } ?? [])
        let filter = SCContentFilter(display: display,
                                     excludingWindows: excluded)
        let current = generation
        inspectedGeneration = current
        scanning = true
        view.isReading = currentSentence == nil
        Task { await inspectFocus(pointer: pointer, generation: current,
                                  screen: screen, filter: filter) }
    }

    private func inspectFocus(pointer: CGPoint, generation current: Int,
                              screen: NSScreen, filter: SCContentFilter) async {
        defer { scanning = false }
        do {
            // Diagnostic switch exercises the pixel path on apps with reliable
            // AX hit geometry; normal launches keep the fast AX path.
            func visualOnly(_ selection: LiveSelection) -> LiveSelection {
                guard CommandLine.arguments.contains("--force-visual-selection") else {
                    return selection
                }
                return LiveSelection(text: selection.text, state: selection.state,
                                     pointHit: false, geometryAvailable: false)
            }
            let initialSelection = visualOnly(readLiveSelection(at: pointer))
            if handleSelectedPointHit(initialSelection, pointer: pointer, generation: current) {
                return
            }
            if activeSelectionSource == "accessibility" {
                activeSelectionHint = nil
                activeSelectionSource = "none"
                selectionRequestID += 1
                pendingSelectionText = nil
                if showingSelectionCard {
                    translationPanel.orderOut(nil)
                    showingSelectionCard = false
                }
                print("SELECTION_HIT source=accessibility geometry=no")
            }
            // The OCR request runs separately, so it cannot hold the visual frame gate.
            let scan = wordScanFrame(around: pointer, on: screen)
            let scanConfig = SCStreamConfiguration()
            scanConfig.sourceRect = CGRect(x: scan.minX - screen.frame.minX,
                                           y: screen.frame.maxY - scan.maxY,
                                           width: scan.width, height: scan.height)
            let ocrScale = min(screen.backingScaleFactor, 1.5)
            scanConfig.width = Int(scan.width * ocrScale)
            scanConfig.height = Int(scan.height * ocrScale)
            scanConfig.showsCursor = false
            let scanStart = uptime()
            let scanImage = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                       configuration: scanConfig)
            let scanMs = ms(scanStart)
            let focus = CGPoint(x: (pointer.x - scan.minX) / scan.width,
                                y: (pointer.y - scan.minY) / scan.height)
            let hint = clipboardHint
            let (passage, ocrMs) = try await Task.detached(priority: .userInitiated) {
                return try passageAtCenter(scanImage, focus: focus, clipboardHint: hint)
            }.value
            guard panel.isVisible, current == generation else { return }
            let live = visualOnly(readLiveSelection(at: pointer))
            if handleSelectedPointHit(live, pointer: pointer, generation: current) { return }
            let candidate = live.text == nil ? initialSelection : live
            if visuallyConfirmedSelection(candidate, passage: passage,
                                          image: scanImage, focus: focus) {
                let visual = LiveSelection(text: candidate.text, state: candidate.state,
                                           pointHit: true, geometryAvailable: false)
                if handleSelectedPointHit(visual, pointer: pointer, generation: current,
                                          sourceName: "accessibility-visual") { return }
            }
            let source = "none"
            let selectionHint: String? = nil
            if activeSelectionHint != selectionHint || activeSelectionSource != source {
                selectionRequestID += 1
                pendingSelectionText = nil
                activeSelectionHint = selectionHint
                activeSelectionSource = source
                print("SELECTION_SOURCE source=\(source) axState=\(live.state) length=\(selectionHint?.count ?? 0)")
                fflush(stdout)
            }
            view.isReading = false
            guard let passage else {
                if showingSelectionCard {
                    translationPanel.orderOut(nil)
                    showingSelectionCard = false
                }
                if let hint = clipboardHint, clipboardWords(hint).count == 1 {
                    clipboardHintMisses += 1
                    if clipboardHintMisses >= 2 {
                        endClipboardHint(reason: "no-visual-focus")
                    }
                }
                if currentSentence != nil {
                    generation += 1
                    currentSentence = nil
                    currentAnchor = nil
                    currentFocusLine = nil
                    currentFocusWordIndex = nil
                    pendingTranslationKey = nil
                    translationPanel.orderOut(nil)
                    print("FOCUS_CONTENT_CHANGED target=none")
                }
                consecutiveMisses += 1
                inspectedGeneration = -1
                nextInspectionAt = uptime() + min(0.45 * pow(1.6, Double(consecutiveMisses - 1)), 2.0)
                print(String(format: "SENTENCE_FOCUS none scanMs=%.1f ocrMs=%.1f", scanMs, ocrMs))
                fflush(stdout)
                return
            }
            consecutiveMisses = 0
            if let hint = clipboardHint {
                if hintSupportsFocus(hint, anchor: passage.anchor) {
                    clipboardHintMisses = 0
                    print("CLIPBOARD_HINT corroborated=true")
                } else if clipboardWords(hint).count == 1 {
                    endClipboardHint(reason: "different-visual-focus")
                }
            }
            if currentAnchor != passage.anchor || currentSentence != passage.sentence {
                generation += 1
                pendingTranslationKey = nil
                translationPanel.orderOut(nil)
                print("FOCUS_CONTENT_CHANGED target=word")
            }
            currentSentence = passage.sentence
            currentAnchor = passage.anchor
            currentFocusLine = passage.focusLine
            currentFocusWordIndex = passage.focusWordIndex
            // The page may scroll beneath a stationary lens. Recheck without
            // restarting a translation request for an unchanged passage.
            inspectedGeneration = -1
            nextInspectionAt = uptime() + 0.6
            print(String(format: "SENTENCE_FOCUS found anchorLength=%d sentenceLength=%d distance=%.3f scanMs=%.1f ocrMs=%.1f",
                         passage.anchor.count, passage.sentence.count, passage.distance, scanMs, ocrMs))
            fflush(stdout)
            if showingSelectionCard {
                translationPanel.orderOut(nil)
                showingSelectionCard = false
            }
            let cacheKey = passage.anchor.lowercased() + "\n" + passage.sentence
            if let literal = passage.literalTranslation {
                let translation = FocusedTranslation(chinese: literal, basis: "时间表达")
                translationCache[cacheKey] = translation
                showFocusCard(literal, anchor: passage.anchor,
                              basis: translation.basis, pointer: pointer)
                print("FOCUS_TRANSLATION resolved=yes basis=时间表达 cloudCalls=0")
                fflush(stdout)
                return
            }
            if let cached = translationCache[cacheKey] {
                if let chinese = cached.chinese {
                    showFocusCard(chinese, anchor: passage.anchor,
                                  basis: cached.basis, pointer: pointer)
                }
                print("FOCUS_TRANSLATION cacheHit=true resolved=\(cached.chinese != nil) basis=\(cached.basis) cloudCalls=0")
                fflush(stdout)
            } else if pendingTranslationKey != cacheKey {
                guard languageSetup.isReady else { return }
                pendingTranslationKey = cacheKey
                bridge.translate(anchor: passage.anchor, sentence: passage.sentence,
                                 maskedSentence: passage.maskedSentence,
                                 localContext: passage.localContext,
                                 maskedLocalContext: passage.maskedLocalContext,
                                 microContext: passage.microContext,
                                 maskedMicroContext: passage.maskedMicroContext,
                                 prefixContext: passage.prefixContext,
                                 maskedPrefixContext: passage.maskedPrefixContext,
                                 generation: generation)
            }
        } catch {
            if current == generation {
                view.isReading = false
                inspectedGeneration = -1
                nextInspectionAt = uptime() + 0.8
            }
            print("FOCUS_SCAN_ERROR=\(error)")
            fflush(stdout)
        }
    }

    private func receiveTranslation(generation current: Int,
                                    result: Result<(FocusedTranslation, Double), Error>) {
        guard panel.isVisible, current == generation,
              let currentSentence, let currentAnchor else { return }
        pendingTranslationKey = nil
        if activeSelectionSource != "none" ||
           readLiveSelection(at: fixedPoint ?? NSEvent.mouseLocation).pointHit { return }
        switch result {
        case .success(let (translation, elapsed)):
            translationFailures = 0
            let cacheKey = currentAnchor.lowercased() + "\n" + currentSentence
            translationCache[cacheKey] = translation
            if let chinese = translation.chinese {
                showFocusCard(chinese, anchor: currentAnchor,
                              basis: translation.basis,
                              pointer: fixedPoint ?? NSEvent.mouseLocation)
            } else {
                translationPanel.orderOut(nil)
            }
            print(String(format: "FOCUS_TRANSLATION translatedMs=%.1f resolved=%@ basis=%@ cloudCalls=0",
                         elapsed, translation.chinese == nil ? "no" : "yes",
                         translation.basis))
        case .failure(let error):
            print("SENTENCE_TRANSLATION_ERROR=\(error)")
            Task { await languageSetup.refresh() }
            if translationFailures == 0 {
                translationFailures = 1
                inspectedGeneration = -1
                nextInspectionAt = uptime() + 0.8
            }
        }
        fflush(stdout)
    }
}
