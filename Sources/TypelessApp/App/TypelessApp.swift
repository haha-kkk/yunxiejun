import AppKit
import Combine
import SwiftUI

@main
struct Typeless01App {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let fnMonitor = FnKeyMonitor()
    private let sessionValidation = SessionValidationController()
    private let microphone = MicrophoneRecordingController()
    private let dictationRecording = MicrophoneRecordingController(mode: .dictation)
    private let apiSettings = APISettingsController()
    private let vocabularyReader = LocalVocabularyReader()
    private lazy var vocabulary = VocabularyListController(reader: vocabularyReader)
    private lazy var archive = TranscriptArchiveController(store: vocabularyReader)
    private let externalTextProbe = ExternalTextProbeController()
    private lazy var correctionLearning = CorrectionLearningController(
        store: vocabularyReader, probe: ExternalTextProbeController(), dismissalPolicy: .afterThreeNewCorrections
    )
    private var correctionPrompt: CorrectionPromptController?
    private lazy var recognition = SpeechRecognitionController(
        service: BailianSpeechRecognitionService(keys: apiSettings.store, vocabulary: vocabularyReader)
    )
    private lazy var cleanup = TextCleanupController(
        service: TextCleanupService(generator: BailianTextCleanupGenerator(keys: apiSettings.store), vocabulary: vocabularyReader)
    )
    private var sessionOverlay: SessionOverlayController?
    private var dictationOverlay: SessionOverlayController?
    private let resultOverlayModel = ResultOverlayModel()
    private var resultOverlay: ResultOverlayController?
    private lazy var dictation = DictationController(
        recording: dictationRecording,
        recognition: BailianSpeechRecognitionService(keys: apiSettings.store, vocabulary: vocabularyReader),
        cleaning: TextCleanupService(generator: BailianTextCleanupGenerator(keys: apiSettings.store), vocabulary: vocabularyReader),
        output: FocusedTextOutputWriter(backend: MacFocusedTextOutputBackend(), usesClipboard: {
            UserDefaults.standard.object(forKey: "clipboardCompatibilityInput") as? Bool ?? true
        })
    )
    private var interruptionMonitor: SessionInterruptionMonitor?
    // AppKit 不会替应用持有状态栏入口和关闭后的窗口。
    private var statusItem: NSStatusItem?
    private var validationWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var archiveWindow: NSWindow?
    private var toggleItem: NSMenuItem?
    private var statusTextItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        microphone.cleanAbandonedRecordings()
        sessionOverlay = SessionOverlayController(session: sessionValidation)
        dictationOverlay = SessionOverlayController(phases: dictation.$overlayPhase.eraseToAnyPublisher())
        resultOverlayModel.connect(to: dictation)
        resultOverlay = ResultOverlayController(model: resultOverlayModel)
        archive.connect(to: dictation)
        archive.openWindow = { [weak self] in self?.showArchiveWindow() }
        resultOverlayModel.openArchive = { [weak self] in self?.showArchiveWindow() }
        dictation.canStart = { [weak self] in
            guard let self else { return false }
            return !self.microphone.isBusy && !self.recognition.isBusy && !self.cleanup.isBusy
        }
        dictation.onWillStart = { [weak self] in
            self?.sessionValidation.handleEscape()
            self?.externalTextProbe.stop()
            self?.correctionLearning.stopObserving()
        }
        dictation.onOutputDelivered = { [weak self] context in
            self?.correctionLearning.startAfterOutput(context)
        }
        correctionLearning.onAccepted = { [weak self] result in self?.vocabulary.receiveAutomaticAddition(result) }
        correctionLearning.canSave = { [weak self] in self?.vocabulary.isSaving == false }
        correctionPrompt = CorrectionPromptController(learning: correctionLearning)
        correctionLearning.reloadPending()
        interruptionMonitor = SessionInterruptionMonitor(session: sessionValidation, keyboard: fnMonitor) {
            [weak self] in
            self?.microphone.cancelIfActive()
            self?.dictation.cancel()
            self?.recognition.cancelIfActive()
            self?.cleanup.cancelIfActive()
            self?.externalTextProbe.stop(reason: "系统会话已中断，验证已停止。")
            self?.correctionLearning.stopObserving()
        }
        fnMonitor.onFnTap = { [weak self] in
            self?.dictation.handleFn()
        }
        fnMonitor.onEscape = { [weak self] in
            self?.correctionLearning.stopObserving()
            self?.dictation.cancel()
            self?.microphone.cancelIfActive()
            self?.recognition.cancelIfActive()
            self?.cleanup.cancelIfActive()
            self?.sessionValidation.handleEscape()
        }
        fnMonitor.onListeningStopped = { [weak self] in
            self?.correctionLearning.stopObserving()
            self?.dictation.cancel()
            self?.microphone.cancelIfActive()
            self?.recognition.cancelIfActive()
            self?.cleanup.cancelIfActive()
            self?.sessionValidation.handleEscape()
        }
        configureApplicationMenu()
        configureStatusItem()
        showValidationWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor.stop()
        recognition.reset()
        cleanup.reset()
        vocabulary.cancelLoading()
        externalTextProbe.clearResults()
        correctionLearning.stopObserving()
        microphone.deleteClip()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 等当前本地事务给出结果，再允许退出；不丢掉已按下“保存”的操作反馈。
        vocabulary.isSaving || correctionLearning.isSaving || archive.isSaving ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showValidationWindow()
        return true
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "云写君")
        appMenu.addItem(makeItem("打开语音输入窗口", action: #selector(showValidationWindow)))
        appMenu.addItem(makeItem("设置…", action: #selector(showSettingsWindow), key: ","))
        appMenu.addItem(makeItem("归档…", action: #selector(showArchiveWindow)))
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem("退出 云写君", action: #selector(quit), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        // 标准响应链让 SecureField 支持粘贴，不从应用代码读取剪贴板。
        for (title, action, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "云写君")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = "云写君"
            button.toolTip = "云写君 · 语音输入"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let title = NSMenuItem(title: "云写君", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(makeItem("打开语音输入窗口", action: #selector(showValidationWindow)))
        menu.addItem(makeItem("设置…", action: #selector(showSettingsWindow)))
        menu.addItem(makeItem("归档…", action: #selector(showArchiveWindow)))
        menu.addItem(.separator())

        let toggle = makeItem("开始监听 Fn", action: #selector(toggleListening))
        menu.addItem(toggle)
        toggleItem = toggle
        let status = NSMenuItem(title: fnMonitor.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusTextItem = status

        menu.addItem(.separator())
        menu.addItem(makeItem("退出 云写君", action: #selector(quit)))
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleItem?.title = fnMonitor.isListening ? "停止 Fn 监听" : "开始监听 Fn"
        statusTextItem?.title = fnMonitor.status
    }

    @objc private func toggleListening() {
        if fnMonitor.isListening {
            fnMonitor.stop()
        } else {
            fnMonitor.start()
        }
    }

    @objc private func showValidationWindow() {
        if validationWindow == nil {
            validationWindow = makeWindow(
                title: "云写君 · 语音输入",
                size: NSSize(width: 840, height: 660),
                content: ContentView()
                    .environmentObject(fnMonitor)
                    .environmentObject(dictation)
                    .environmentObject(archive)
                    .environmentObject(sessionValidation)
                    .environmentObject(microphone)
                    .environmentObject(recognition)
                    .environmentObject(cleanup)
                    .environmentObject(externalTextProbe)
                    .environmentObject(correctionLearning)
            )
        }
        present(validationWindow)
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "云写君 · 设置",
                size: NSSize(width: 660, height: 570),
                content: SettingsView().environmentObject(apiSettings).environmentObject(vocabulary)
            )
        }
        Task { await apiSettings.refresh() }
        vocabulary.reload()
        present(settingsWindow)
    }

    @objc private func showArchiveWindow() {
        if archiveWindow == nil {
            archiveWindow = makeWindow(title: "云写君 · 归档", size: NSSize(width: 660, height: 570),
                                       content: TranscriptArchiveView(archive: archive))
        }
        archive.reload()
        present(archiveWindow)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow, vocabulary.isSaving { return false }
        if sender === validationWindow {
            if correctionLearning.isSaving { return false }
            correctionLearning.stopObserving()
            externalTextProbe.stop()
            microphone.cancelIfActive()
            recognition.cancelIfActive()
            cleanup.cancelIfActive()
        }
        if sender === settingsWindow {
            apiSettings.clearDraft()
            vocabulary.cancelLoading()
            vocabulary.dismissEditor()
        }
        sender.orderOut(nil)
        return false
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
