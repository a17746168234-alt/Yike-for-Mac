import SwiftUI
import AppKit
import Speech
import AVFoundation
import Translation
import Vision
import NaturalLanguage
import UniformTypeIdentifiers
import ApplicationServices
import Carbon.HIToolbox

let maxSourceCharacters = 5_000
var globalShortcutDescription: String { SelectionShortcut.load().label }

extension Notification.Name {
    static let openYikeSettings = Notification.Name("openYikeSettings")
    static let translateSelectedText = Notification.Name("translateSelectedText")
    static let selectionShortcutChanged = Notification.Name("selectionShortcutChanged")
}

struct SelectedTextCapture {
    let text: String
    let anchor: CGPoint
}

final class GlobalHotKeyController {
    static weak var active: GlobalHotKeyController?
    private var currentShortcut: SelectionShortcut?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                NotificationCenter.default.post(
                    name: .translateSelectedText,
                    object: nil,
                    userInfo: processID.map { ["pid": Int($0)] }
                )
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        Self.active = self
        _ = apply(SelectionShortcut.load())
    }

    @discardableResult
    func apply(_ value: SelectionShortcut) -> OSStatus {
        guard value.validationError == nil else { return OSStatus(paramErr) }
        if currentShortcut == value && hotKeyRef != nil { return noErr }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(
            value.keyCode, value.modifiers,
            EventHotKeyID(signature: 0x46594E59, id: 1),
            GetApplicationEventTarget(), 0, &replacement
        )
        guard status == noErr else { return status }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = replacement
        currentShortcut = value
        value.save()
        NotificationCenter.default.post(name: .selectionShortcutChanged, object: nil)
        return noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var globalHotKeyController: GlobalHotKeyController?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var pendingSingleClick: DispatchWorkItem?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleRunningInstance() else { return }
        globalHotKeyController = GlobalHotKeyController()
        configureStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshShortcutLabels),
                                               name: .selectionShortcutChanged, object: nil)
        DispatchQueue.main.async { [weak self] in
            self?.captureMainWindow()
        }
    }

    private func claimSingleRunningInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard let existingInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentProcessID && !$0.isTerminated }) else {
            return true
        }

        existingInstance.activate(options: [.activateIgnoringOtherApps])
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    private func captureMainWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.level == .normal && $0.styleMask.contains(.titled)
        }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.captureMainWindow()
            }
            return
        }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 934, height: 592)
        window.collectionBehavior.insert(.fullScreenPrimary)
        NSApp.setActivationPolicy(.regular)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        sender.orderOut(nil)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.image = MenuBarIcon.make()
            button.toolTip = "Yike · \(globalShortcutDescription) 划词翻译"
        }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开 Yike", action: #selector(showMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let screenshotItem = NSMenuItem(title: "截图翻译", action: #selector(translateScreenshot), keyEquivalent: "")
        screenshotItem.target = self
        menu.addItem(screenshotItem)
        let voiceItem = NSMenuItem(title: "语音输入", action: #selector(translateVoice), keyEquivalent: "")
        voiceItem.target = self
        menu.addItem(voiceItem)
        let shortcutItem = NSMenuItem(title: "划词翻译：\(globalShortcutDescription)", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        shortcutItem.tag = 1001
        menu.addItem(shortcutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Yike", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusMenu = menu
        statusItem = item
    }

    @objc private func statusItemClicked() {
        pendingSingleClick?.cancel()
        if NSApp.currentEvent?.type == .rightMouseUp || (NSApp.currentEvent?.clickCount ?? 0) >= 2 {
            guard let button = statusItem?.button, let menu = statusMenu else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else {
            let action = DispatchWorkItem { [weak self] in self?.showMainWindow() }
            pendingSingleClick = action
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: action)
        }
    }

    @objc private func openSettings() {
        showMainWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openYikeSettings, object: nil)
        }
    }

    @objc private func refreshShortcutLabels() {
        statusItem?.button?.toolTip = "Yike · \(globalShortcutDescription) 划词翻译"
        statusMenu?.item(withTag: 1001)?.title = "划词翻译：\(globalShortcutDescription)"
    }

    @MainActor @objc private func translateScreenshot() {
        showMainWindow()
        TranslatorViewModel.shared.captureScreenRegionAndTranslate()
    }

    @MainActor @objc private func translateVoice() {
        TranslatorViewModel.shared.startPopupVoiceInput()
    }

    @objc private func showMainWindow() {
        if mainWindow == nil { captureMainWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

}

let languageLabels: [String: String] = [
    "auto": "自动检测",
    "en": "英语",
    "zh-CN": "简体中文",
    "ja": "日语",
    "ko": "韩语",
    "de": "德语",
    "fr": "法语"
]

let concreteLanguages = ["en", "zh-CN", "ja", "ko", "de", "fr"]
let sourceLanguagesWithAuto = ["auto", "en", "zh-CN", "ja", "ko", "de", "fr"]

let speechLocales: [String: String] = [
    "en": "en-US",
    "zh-CN": "zh-CN",
    "ja": "ja-JP",
    "ko": "ko-KR",
    "de": "de-DE",
    "fr": "fr-FR"
]

let appleTranslationLocales: [String: String] = [
    "en": "en",
    "zh-CN": "zh",
    "ja": "ja",
    "ko": "ko",
    "de": "de",
    "fr": "fr"
]

func languageName(_ code: String) -> String {
    languageLabels[code] ?? code
}

func historyTimeText(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

enum ImageRecognitionError: LocalizedError {
    case unreadableImage
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取这张图片，请换一张常见格式的图片重试"
        case .noTextFound: return "图片中没有识别到可翻译的文字"
        }
    }
}

enum AppTranslationError: LocalizedError {
    case invalidRequest
    case serviceUnavailable
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "翻译请求无效"
        case .serviceUnavailable: return "翻译服务暂时不可用"
        case .provider(let message): return message
        }
    }
}

@main
struct TranslationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Yike", id: "main") {
            TranslatorView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1060, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
