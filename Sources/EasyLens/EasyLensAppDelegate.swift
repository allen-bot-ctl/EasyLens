// Migrated from the validated macOS lens prototype.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import ScreenCaptureKit
import SwiftUI

@MainActor
final class EasyLensAppDelegate: NSObject, NSApplicationDelegate {
    private enum RemoteLoading {
        case word(generation: Int, key: String, anchor: String)
        case selection(requestID: Int, text: String)
    }

    private let lensSize = CGSize(width: 190, height: 114)
    private let bridge = WordTranslationBridge()
    private let selectionBridge = SelectionTranslationBridge()
    private let languageSetup = TranslationLanguageSetup()
    private let translationSettings = TranslationSettings()
    private let deepSeekClient = DeepSeekTranslationClient()
    private var settingsWindow: NSWindow?
    private var remoteWordTask: Task<Void, Never>?
    private var remoteSelectionTask: Task<Void, Never>?
    private var languageSetupWindow: NSWindow?
    private var languageMenuItem: NSMenuItem!
    private var languageSetupTimer: Timer?
    private var hasPresentedLanguageSetup = false
    private var accessibilityMenuItem: NSMenuItem!
    private var accessibilityTimer: Timer?
    private var hasPresentedAccessibilitySetup = false
    private var accessibilityTrusted: Bool?
    private var screenCaptureMenuItem: NSMenuItem!
    private var hasPresentedScreenCaptureSetup = false
    private var screenCaptureTrusted: Bool?
    private var selectionTargetPID: pid_t?
    private var applicationActivationObserver: NSObjectProtocol?
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
    private var selectionVisualMisses = 0
    private var selectionRequestID = 0
    private var pendingSelectionText: String?
    private var selectionCache: [String: String] = [:]
    private var showingSelectionCard = false
    private var remoteLoading: RemoteLoading?
    private var remoteLoadingAfter = 0.0
    private var isLoadingCard = false
    private var loadingDots: [CALayer] = []
    private var lastSelectionDiagnostic: String?
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
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        languageMenuItem = NSMenuItem(title: "检查英中翻译语言…",
                                      action: #selector(showLanguageSetup), keyEquivalent: "")
        languageMenuItem.target = self
        menu.addItem(languageMenuItem)
        accessibilityMenuItem = NSMenuItem(title: "选区识别：检查权限…",
                                           action: #selector(showAccessibilitySetup),
                                           keyEquivalent: "")
        accessibilityMenuItem.target = self
        menu.addItem(accessibilityMenuItem)
        screenCaptureMenuItem = NSMenuItem(title: "屏幕读取：检查权限…",
                                           action: #selector(showScreenCaptureSetup),
                                           keyEquivalent: "")
        screenCaptureMenuItem.target = self
        menu.addItem(screenCaptureMenuItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 EasyLens", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        installHotKeys()
        rememberSelectionTarget(NSWorkspace.shared.frontmostApplication)
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil,
            queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                Task { @MainActor [weak self] in
                    self?.rememberSelectionTarget(application)
                }
            }
        updateAccessibilityStatus()
        updateScreenCaptureStatus()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAccessibilityStatus()
                self?.updateScreenCaptureStatus()
            }
        }
        print("EASYLENS_READY ⌃⌥L toggles eye lens; Esc hides; EL◉ menu quits")
        print("TRANSLATION_PROVIDER=\(translationSettings.provider.rawValue) screenshots_saved=0")
        fflush(stdout)
        languageSetup.onStatusChange = { [weak self] status in
            self?.languageStatusChanged(status)
        }
        translationSettings.onChange = { [weak self] in
            self?.translationSettingsChanged()
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
        if translationSettings.provider == .local {
            Task { await languageSetup.refresh() }
        }
        languageSetupTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.translationSettings.provider == .local,
                      !self.languageSetup.isReady else { return }
                await self.languageSetup.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        remoteWordTask?.cancel()
        remoteSelectionTask?.cancel()
        timer?.invalidate()
        languageSetupTimer?.invalidate()
        accessibilityTimer?.invalidate()
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
        }
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

    private func rememberSelectionTarget(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        selectionTargetPID = application.processIdentifier
    }

    private func updateAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        accessibilityMenuItem.title = trusted ? "选区识别：已授权" :
            "选区识别：需要辅助功能权限…"
        accessibilityMenuItem.isEnabled = !trusted
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted
        NSLog("EASYLENS_ACCESSIBILITY trusted=%@", trusted ? "yes" : "no")
        if trusted {
            inspectedGeneration = -1
            nextInspectionAt = 0
        }
    }

    private func recordSelectionDiagnostic(_ selection: LiveSelection) {
        let status = "state=\(selection.state) length=\(selection.text?.count ?? 0) hit=\(selection.pointHit) targetPID=\(selectionTargetPID ?? 0)"
        guard status != lastSelectionDiagnostic else { return }
        lastSelectionDiagnostic = status
        NSLog("EASYLENS_SELECTION %@", status)
    }

    private func updateScreenCaptureStatus() {
        let trusted = CGPreflightScreenCaptureAccess()
        screenCaptureMenuItem.title = trusted ? "屏幕读取：已授权" :
            "屏幕读取：需要录屏权限…"
        screenCaptureMenuItem.isEnabled = !trusted
        guard trusted != screenCaptureTrusted else { return }
        screenCaptureTrusted = trusted
        NSLog("EASYLENS_SCREEN_CAPTURE granted=%@", trusted ? "yes" : "no")
    }

    @objc private func showScreenCaptureSetup() {
        _ = presentScreenCaptureSetup()
    }

    private func presentScreenCaptureSetup() -> Bool {
        let alert = NSAlert()
        alert.messageText = "开启屏幕读取"
        alert.informativeText = "EasyLens 需要 macOS 的“屏幕与系统音频录制”权限，才能识别鼠标附近的文字。应用只读取画面，不录音，也不保存截图。\n\n请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 EasyLens。如果列表里没有它，点列表底部的“＋”，在文件选择窗口按 ⇧⌘G，输入以下路径后添加：\n\(Bundle.main.bundleURL.path)\n\nmacOS 可能要求退出并重新打开 EasyLens，授权才会生效。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let granted = CGRequestScreenCaptureAccess()
        NSLog("EASYLENS_SCREEN_CAPTURE_REQUEST granted=%@", granted ? "yes" : "no")
        if !granted,
           let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            let opened = NSWorkspace.shared.open(url)
            NSLog("EASYLENS_SCREEN_CAPTURE_SETTINGS opened=%@", opened ? "yes" : "no")
        }
        updateScreenCaptureStatus()
        return true
    }

    @objc private func showAccessibilitySetup() {
        _ = presentAccessibilitySetup()
    }

    // Returns true when the user chose Settings, so the lens can stay hidden
    // while macOS displays the permission controls.
    private func presentAccessibilitySetup() -> Bool {
        let alert = NSAlert()
        alert.messageText = "开启完整选区翻译"
        alert.informativeText = "完整选区翻译需要“辅助功能”权限，以读取所选文字并确认眼睛中心位于选区内。未授权时仍可翻译单词。请在“系统设置 → 隐私与安全性 → 辅助功能”允许 EasyLens。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "暂时使用单词翻译")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    private func releaseEscape() {
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey); self.escapeHotKey = nil }
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : showLens()
    }

    private func showLens() {
        rememberSelectionTarget(NSWorkspace.shared.frontmostApplication)
        if !CGPreflightScreenCaptureAccess() {
            if !hasPresentedScreenCaptureSetup {
                hasPresentedScreenCaptureSetup = true
                _ = presentScreenCaptureSetup()
            }
            return
        }
        if !AXIsProcessTrusted(), !hasPresentedAccessibilitySetup {
            hasPresentedAccessibilitySetup = true
            if presentAccessibilitySetup() { return }
        }
        if translationSettings.provider == .local {
            Task { await languageSetup.refresh() }
        }
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
        finishRemoteLoading()
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
        remoteWordTask?.cancel()
        remoteSelectionTask?.cancel()
        finishRemoteLoading()
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

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 430),
                                  styleMask: [.titled, .closable], backing: .buffered,
                                  defer: false)
            window.title = "EasyLens · 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TranslationSettingsView(
                settings: translationSettings, onDismiss: { [weak self] in
                    self?.settingsWindow?.orderOut(nil)
                }))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func translationSettingsChanged() {
        remoteWordTask?.cancel()
        remoteSelectionTask?.cancel()
        finishRemoteLoading()
        generation += 1
        selectionRequestID += 1
        pendingTranslationKey = nil
        pendingSelectionText = nil
        translationCache.removeAll()
        selectionCache.removeAll()
        translationPanel.orderOut(nil)
        showingSelectionCard = false
        currentSentence = nil
        currentAnchor = nil
        inspectedGeneration = -1
        nextInspectionAt = 0
        view.hasTranslation = false
        if translationSettings.provider == .local {
            Task { await languageSetup.refresh() }
        }
    }

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
            if translationSettings.provider == .local && !hasPresentedLanguageSetup {
                hasPresentedLanguageSetup = true
                showLanguageSetup()
            }
        case .downloading:
            languageMenuItem.title = "英中翻译语言下载中…"
        case .unsupported:
            languageMenuItem.title = "英中翻译语言不可用…"
            if translationSettings.provider == .local && !hasPresentedLanguageSetup {
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

    private func beginRemoteLoading(_ loading: RemoteLoading) {
        finishRemoteLoading()
        translationPanel.orderOut(nil)
        view.hasTranslation = false
        remoteLoading = loading
        remoteLoadingAfter = uptime() + 0.18
    }

    private func finishRemoteLoading() {
        remoteLoading = nil
        remoteLoadingAfter = 0
        for dot in loadingDots { dot.removeFromSuperlayer() }
        loadingDots.removeAll()
        translationPanel.contentView?.layer?.removeAnimation(forKey: "loadingAppear")
        if isLoadingCard {
            translationPanel.orderOut(nil)
            wordLabel.stringValue = ""
            contextLabel.stringValue = ""
        }
        isLoadingCard = false
    }

    private func showRemoteLoadingIfNeeded(at pointer: CGPoint, now: Double) {
        guard !isLoadingCard, now >= remoteLoadingAfter,
              let loading = remoteLoading else { return }
        let title: String
        switch loading {
        case .word(let requestGeneration, let key, let anchor):
            guard requestGeneration == generation,
                  pendingTranslationKey == key, currentAnchor == anchor else {
                finishRemoteLoading()
                return
            }
            title = anchor
        case .selection(let requestID, let text):
            guard requestID == selectionRequestID, pendingSelectionText == text,
                  activeSelectionHint == text else {
                finishRemoteLoading()
                return
            }
            let live = readLiveSelection(at: pointer, targetPID: selectionTargetPID)
            guard live.text == text else {
                if live.text != nil { finishRemoteLoading() }
                else { remoteLoadingAfter = now + 0.12 }
                return
            }
            title = "完整选区"
        }
        showLoadingCard(title: title, pointer: pointer)
    }

    private func showLoadingCard(title: String, pointer: CGPoint) {
        guard let screen = screen(at: pointer), let card = translationPanel.contentView else { return }
        let width = min(CGFloat(320), max(CGFloat(210), CGFloat(title.count) * 8 + 90))
        let height: CGFloat = 76
        translationPanel.setContentSize(CGSize(width: width, height: height))
        card.frame = CGRect(x: 0, y: 0, width: width, height: height)
        wordLabel.stringValue = title
        wordLabel.frame = CGRect(x: 16, y: 48, width: width - 32, height: 18)
        contextLabel.font = .systemFont(ofSize: 15, weight: .medium)
        contextLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        contextLabel.stringValue = "正在转译"
        contextLabel.frame = CGRect(x: 16, y: 11, width: 94, height: 30)
        for index in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: 114 + CGFloat(index) * 12, y: 24,
                               width: 4, height: 4)
            dot.cornerRadius = 2
            dot.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
            dot.opacity = 0.22
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.22, 0.9, 0.22]
            pulse.keyTimes = [0, 0.5, 1]
            pulse.duration = 1.15
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.16
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "pulse")
            card.layer?.addSublayer(dot)
            loadingDots.append(dot)
        }
        let eyeFrame = panel.frame
        let x = max(screen.frame.minX + 6,
                    min(eyeFrame.midX - width / 2, screen.frame.maxX - width - 6))
        let below = eyeFrame.minY - height - 8
        let y = below >= screen.frame.minY + 6 ? below :
            min(eyeFrame.maxY + 8, screen.frame.maxY - height - 6)
        translationPanel.setFrameOrigin(CGPoint(x: x, y: y))
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.14
        card.layer?.add(appear, forKey: "loadingAppear")
        isLoadingCard = true
        translationPanel.orderFrontRegardless()
        view.hasTranslation = false
    }

    private func showFocusCard(_ chinese: String, anchor: String, basis: String,
                               pointer: CGPoint) {
        guard let screen = screen(at: pointer) else { return }
        finishRemoteLoading()
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
        contextLabel.textColor = .white
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
        finishRemoteLoading()
        showingSelectionCard = true
        let width: CGFloat = min(420, max(250, screen.frame.width - 12))
        let contentWidth = width - 32
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let measured = (chinese as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height
        contextLabel.font = font
        contextLabel.textColor = .white
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
                finishRemoteLoading()
                endClipboardHint(reason: "empty-selection-translation")
                inspectedGeneration = -1
                nextInspectionAt = 0
                return
            }
            selectionCache[source] = translated
            let pointer = fixedPoint ?? NSEvent.mouseLocation
            let stillSelected: Bool
            if activeSelectionSource == "accessibility" {
                let live = readLiveSelection(at: pointer, targetPID: selectionTargetPID)
                stillSelected = live.pointHit && live.text == source
            } else {
                // The pixel hit was checked in the same pointer generation.
                // Movement or a changed AX selection invalidates it; the next
                // scan can use the cache after checking the visible frame.
                let live = readLiveSelection(at: pointer, targetPID: selectionTargetPID)
                stillSelected = activeSelectionSource == "accessibility-visual" &&
                    selectionHitGeneration == generation && live.text == source &&
                    hypot(pointer.x - selectionHitPointer.x,
                          pointer.y - selectionHitPointer.y) < 3
            }
            if panel.isVisible, activeSelectionHint == source,
               stillSelected {
                showSelectionCard(translated, pointer: fixedPoint ?? NSEvent.mouseLocation)
            } else {
                finishRemoteLoading()
            }
            print(String(format: "SELECTION_TRANSLATION translatedMs=%.1f resolved=yes sourceLength=%d targetLength=%d provider=%@",
                         elapsed, source.count, translated.count, translationSettings.provider.rawValue))
        case .failure(let error):
            finishRemoteLoading()
            print("SELECTION_TRANSLATION_ERROR=\(error)")
            if translationSettings.provider == .local {
                Task { await languageSetup.refresh() }
            }
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
        selectionVisualMisses = 0
        let selected = live.text
        if activeSelectionHint != selected {
            remoteSelectionTask?.cancel()
            selectionRequestID += 1
            pendingSelectionText = nil
            print("SELECTION_HIT source=\(sourceName) length=\(selected?.count ?? 0) axState=\(live.state)")
        }
        activeSelectionHint = selected
        activeSelectionSource = sourceName
        remoteWordTask?.cancel()
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
        } else if let selected, pendingSelectionText == selected,
                  translationSettings.provider == .deepSeek, remoteLoading == nil {
            // The pointer may have briefly left and re-entered this selection.
            // Reattach the waiting UI to the same request without a new call.
            beginRemoteLoading(.selection(requestID: selectionRequestID, text: selected))
        } else if let selected, pendingSelectionText != selected {
            guard translationSettings.provider == .deepSeek || languageSetup.isReady else {
                return true
            }
            translationPanel.orderOut(nil)
            showingSelectionCard = false
            selectionRequestID += 1
            pendingSelectionText = selected
            if translationSettings.provider == .deepSeek {
                let requestID = selectionRequestID
                do {
                    let configuration = try translationSettings.deepSeekConfiguration()
                    beginRemoteLoading(.selection(requestID: requestID, text: selected))
                    remoteSelectionTask?.cancel()
                    remoteSelectionTask = Task {
                        let start = uptime()
                        do {
                            let result = try await deepSeekClient.translateSelection(
                                selected, configuration: configuration)
                            receiveSelectionTranslation(requestID: requestID,
                                                        result: .success((result, ms(start))))
                        } catch where !Task.isCancelled {
                            receiveSelectionTranslation(requestID: requestID, result: .failure(error))
                        } catch {}
                    }
                } catch {
                    receiveSelectionTranslation(requestID: requestID, result: .failure(error))
                }
            } else {
                selectionBridge.translate(selected, requestID: selectionRequestID)
            }
            print("SELECTION_TRANSLATION requested length=\(selected.count) provider=\(translationSettings.provider.rawValue)")
        } else if selected == nil {
            finishRemoteLoading()
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
        rememberSelectionTarget(NSWorkspace.shared.frontmostApplication)
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
            remoteWordTask?.cancel()
            finishRemoteLoading()
            selectionVisualMisses = 0
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
        showRemoteLoadingIfNeeded(at: pointer, now: now)
        let success = now - lastMoveAt >= 0.10 && translationPanel.isVisible &&
            translationPanel.alphaValue > 0.5 && !isLoadingCard &&
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
            let initialSelection = visualOnly(readLiveSelection(at: pointer,
                                                               targetPID: selectionTargetPID))
            recordSelectionDiagnostic(initialSelection)
            if handleSelectedPointHit(initialSelection, pointer: pointer, generation: current) {
                return
            }
            if activeSelectionSource == "accessibility" {
                finishRemoteLoading()
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
            let live = visualOnly(readLiveSelection(at: pointer,
                                                    targetPID: selectionTargetPID))
            recordSelectionDiagnostic(live)
            if handleSelectedPointHit(live, pointer: pointer, generation: current) { return }
            let candidate = live.text == nil ? initialSelection : live
            if visuallyConfirmedSelection(candidate, passage: passage,
                                          image: scanImage, focus: focus) {
                let visual = LiveSelection(text: candidate.text, state: candidate.state,
                                           pointHit: true, geometryAvailable: false)
                if handleSelectedPointHit(visual, pointer: pointer, generation: current,
                                          sourceName: "accessibility-visual") { return }
            }
            // A couple of noisy OCR or highlight frames must not switch an
            // unchanged, stationary selection into word mode while its
            // translation is still in flight.
            if activeSelectionSource == "accessibility-visual",
               candidate.text == activeSelectionHint,
               selectionHitGeneration == current,
               hypot(pointer.x - selectionHitPointer.x,
                     pointer.y - selectionHitPointer.y) < 3,
               selectionVisualMisses < 2 {
                selectionVisualMisses += 1
                inspectedGeneration = -1
                nextInspectionAt = uptime() + 0.12
                return
            }
            selectionVisualMisses = 0
            let source = "none"
            let selectionHint: String? = nil
            if activeSelectionHint != selectionHint || activeSelectionSource != source {
                finishRemoteLoading()
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
                // A single noisy editor frame should not make an already
                // translated word blink out between two successful scans.
                consecutiveMisses += 1
                if currentSentence != nil, consecutiveMisses >= 2 {
                    finishRemoteLoading()
                    generation += 1
                    currentSentence = nil
                    currentAnchor = nil
                    currentFocusLine = nil
                    currentFocusWordIndex = nil
                    pendingTranslationKey = nil
                    translationPanel.orderOut(nil)
                    print("FOCUS_CONTENT_CHANGED target=none")
                }
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
                finishRemoteLoading()
                generation += 1
                pendingTranslationKey = nil
                if currentAnchor != passage.anchor {
                    translationPanel.orderOut(nil)
                }
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
            if translationSettings.provider == .local,
               let literal = passage.literalTranslation {
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
                guard translationSettings.provider == .deepSeek || languageSetup.isReady else {
                    return
                }
                pendingTranslationKey = cacheKey
                if translationSettings.provider == .deepSeek {
                    do {
                        let configuration = try translationSettings.deepSeekConfiguration()
                        let requestGeneration = generation
                        beginRemoteLoading(.word(generation: requestGeneration,
                                                 key: cacheKey, anchor: passage.anchor))
                        remoteWordTask?.cancel()
                        remoteWordTask = Task {
                            let start = uptime()
                            do {
                                let result = try await deepSeekClient.translateWord(
                                    anchor: passage.anchor, sentence: passage.sentence,
                                    configuration: configuration)
                                receiveTranslation(generation: requestGeneration,
                                                   result: .success((result, ms(start))))
                            } catch where !Task.isCancelled {
                                receiveTranslation(generation: requestGeneration,
                                                   result: .failure(error))
                            } catch {}
                        }
                    } catch {
                        receiveTranslation(generation: generation, result: .failure(error))
                    }
                } else {
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
           readLiveSelection(at: fixedPoint ?? NSEvent.mouseLocation,
                             targetPID: selectionTargetPID).pointHit {
            finishRemoteLoading()
            return
        }
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
                finishRemoteLoading()
                translationPanel.orderOut(nil)
            }
            print(String(format: "FOCUS_TRANSLATION translatedMs=%.1f resolved=%@ basis=%@ provider=%@",
                         elapsed, translation.chinese == nil ? "no" : "yes",
                         translation.basis, translationSettings.provider.rawValue))
        case .failure(let error):
            finishRemoteLoading()
            print("SENTENCE_TRANSLATION_ERROR=\(error)")
            if translationSettings.provider == .local {
                Task { await languageSetup.refresh() }
            }
            if translationFailures == 0 {
                translationFailures = 1
                inspectedGeneration = -1
                nextInspectionAt = uptime() + 0.8
            }
        }
        fflush(stdout)
    }
}
