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

final class SelectionTranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SelectionTranslationPanelController: NSObject, NSWindowDelegate {
    private var panel: SelectionTranslationPanel?
    private weak var model: TranslatorViewModel?
    private var sourceProcessID: pid_t?
    private var sourceAppObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private let defaultSize = NSSize(width: 390, height: 235)
    private let minimumSize = NSSize(width: 320, height: 190)
    private let frameAutosaveName = "Mac翻译.划词浮窗"
    private let hasSavedFrameKey = "yijian.popup.has-saved-frame"

    func show(model: TranslatorViewModel, anchor: CGPoint, sourceProcessID: pid_t?) {
        let panel = panel ?? makePanel(model: model, size: defaultSize)
        self.panel = panel
        self.model = model
        self.sourceProcessID = sourceProcessID
        startFollowingSourceApplication()
        startOutsideClickMonitoring()
        let targetScreen = screen(containing: anchor)
        updateSizeLimits(for: panel, on: targetScreen)
        let currentSize = clampedSize(panel.frame.size, for: targetScreen)
        if panel.frame.size != currentSize {
            panel.setContentSize(currentSize)
        }
        if !UserDefaults.standard.bool(forKey: hasSavedFrameKey) {
            panel.setFrameOrigin(panelOrigin(for: currentSize, anchor: anchor, screen: targetScreen))
        } else if let visibleFrame = targetScreen?.visibleFrame, !visibleFrame.intersects(panel.frame) {
            panel.setFrameOrigin(panelOrigin(for: currentSize, anchor: anchor, screen: targetScreen))
        }
        if sourceProcessID == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == sourceProcessID {
            panel.orderFrontRegardless()
        }
    }

    private func close() {
        model?.cancelPopupVoiceInput()
        sourceProcessID = nil
        panel?.orderOut(nil)
        if let sourceAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sourceAppObserver)
            self.sourceAppObserver = nil
        }
    }

    private func replaceSelection() {
        guard let sourceProcessID, let model else { return }
        model.replaceSelectedText(in: sourceProcessID)
        if !model.popupPinned { close() }
    }

    private func startFollowingSourceApplication() {
        if let sourceAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sourceAppObserver)
        }
        sourceAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let sourceProcessID = self.sourceProcessID else { return }
                if app.processIdentifier == sourceProcessID || self.model?.popupPinned == true {
                    self.panel?.orderFrontRegardless()
                } else {
                    self.panel?.orderOut(nil)
                }
            }
        }
    }

    private func makePanel(model: TranslatorViewModel, size: NSSize) -> SelectionTranslationPanel {
        let panel = SelectionTranslationPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentMinSize = minimumSize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.setFrameAutosaveName(frameAutosaveName)
        let hostingView = NSHostingView(
            rootView: SelectionTranslationPopup(
                model: model,
                close: { [weak self] in self?.close() },
                replace: { [weak self] in self?.replaceSelection() }
            )
            .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.setContentSize(size)
        return panel
    }

    private func startOutsideClickMonitoring() {
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hideForOutsideClickIfNeeded() }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                Task { @MainActor in self?.hideForOutsideClickIfNeeded() }
                return event
            }
        }
    }

    private func hideForOutsideClickIfNeeded() {
        guard let panel, panel.isVisible, model?.popupPinned != true else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) { close() }
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: hasSavedFrameKey)
    }

    func windowDidResize(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: hasSavedFrameKey)
    }

    private func screen(containing anchor: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(anchor) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func updateSizeLimits(for panel: NSPanel, on screen: NSScreen?) {
        guard let visibleFrame = screen?.visibleFrame else { return }
        panel.contentMinSize = minimumSize
        panel.contentMaxSize = NSSize(
            width: max(minimumSize.width, floor(visibleFrame.width * 0.5)),
            height: max(minimumSize.height, floor(visibleFrame.height * 0.5))
        )
    }

    private func clampedSize(_ size: NSSize, for screen: NSScreen?) -> NSSize {
        guard let visibleFrame = screen?.visibleFrame else { return size }
        return NSSize(
            width: min(max(size.width, minimumSize.width), floor(visibleFrame.width * 0.5)),
            height: min(max(size.height, minimumSize.height), floor(visibleFrame.height * 0.5))
        )
    }

    private func panelOrigin(for size: NSSize, anchor: CGPoint, screen: NSScreen?) -> NSPoint {
        guard let visibleFrame = screen?.visibleFrame else {
            return NSPoint(x: anchor.x + 12, y: anchor.y - size.height - 10)
        }

        var x = anchor.x + 12
        var y = anchor.y - size.height - 10
        if y < visibleFrame.minY + 8 { y = anchor.y + 22 }
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        y = min(max(y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

struct SelectionTranslationPopup: View {
    @ObservedObject var model: TranslatorViewModel
    let close: () -> Void
    let replace: () -> Void
    private let blue = MacVisualTokens.accent

    var body: some View {
        GeometryReader { geometry in
            let scale = min(max(geometry.size.width / 390, 0.88), 1.45)
            VStack(spacing: 0) {
            HStack(spacing: 9) {
                popupLanguageMenu(selection: model.popupSourceLanguage, excluding: model.popupTargetLanguage, action: model.setPopupSourceLanguage)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.secondary)
                popupLanguageMenu(selection: model.popupTargetLanguage, excluding: model.popupSourceLanguage, action: model.setPopupTargetLanguage)
                Spacer()
                Button {
                    model.popupPinned.toggle()
                } label: {
                    Image(systemName: model.popupPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.popupPinned ? blue : Color.secondary)
                        .frame(width: 27, height: 27)
                        .background((model.popupPinned ? blue : Color.secondary).opacity(0.10))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.popupPinned ? "取消固定" : "固定浮窗")
                Button(action: replace) {
                    Image(systemName: "arrow.uturn.backward.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(blue)
                        .frame(width: 27, height: 27)
                        .background(blue.opacity(0.10))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.popupTranslatedText.isEmpty)
                .help("用译文替换选中文字")
                Button(action: model.copyPopupResult) {
                    Image(systemName: model.copyLabel == "复制译文" ? "doc.on.doc" : "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(blue)
                        .frame(width: 27, height: 27)
                        .background(blue.opacity(0.10))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.popupTranslatedText.isEmpty)
                .help(model.copyLabel)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 25, height: 25)
                        .background(Color.black.opacity(0.045))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider().opacity(0.65)

            VStack(alignment: .leading, spacing: 11) {
                Text(model.popupSourceText)
                    .font(.system(size: min(15 * scale, 20)))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)

                if model.popupVoiceActive {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("正在听，请说中文…", systemImage: "mic.fill")
                        if let countdown = model.popupSilenceCountdown {
                            Text("静音 \(countdown) 秒后翻译")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("完成并翻译", action: model.finishPopupVoiceInput)
                        Button("取消", action: model.cancelPopupVoiceInput)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if model.popupIsLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.popupTranslationProgress).font(.system(size: 14, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if let diagnostic = model.popupNotice?.diagnostic {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            TranslationDiagnosticView(diagnostic: diagnostic)
                            Button("重新尝试", action: model.retryPopupTranslation)
                                .buttonStyle(.bordered)
                            Text("需要设置密钥或切换引擎时，请打开 Yike 主窗口。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else if let notice = model.popupNotice {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(notice.kind.title, systemImage: notice.kind.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(notice.kind.color)
                        Text(notice.message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let action = notice.action {
                            Button(action.buttonTitle) { action.open() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if !model.popupTranslatedText.isEmpty {
                    ScrollView {
                        Text(model.popupTranslatedText)
                            .font(.system(size: min(17 * scale, 24), weight: .medium))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            }
            .background {
                AdaptiveGlassBackdrop(materialOpacity: 0.94, tintOpacity: 0.22)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 320, minHeight: 190)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .padding(6)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if #available(macOS 15.0, *) {
                PopupAppleTranslationWorker(model: model)
            }
        }
    }

    private func popupLanguageMenu(selection: String, excluding: String, action: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(concreteLanguages.filter { $0 != excluding }, id: \.self) { code in
                Button(languageName(code)) { action(code) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(languageName(selection))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(MacVisualTokens.tertiaryLabel)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MacVisualTokens.label)
            .macHoverControl(cornerRadius: 8, horizontalPadding: 8, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

@available(macOS 15.0, *)
struct PopupAppleTranslationWorker: View {
    @ObservedObject var model: TranslatorViewModel
    var body: some View {
        if let request = model.popupAppleTranslationRequest {
            AppleRequestSession(source: request.source, target: request.target) { session in
                await model.completePopupAppleTranslation(using: session, request: request)
            }
            .id(request.id)
        }
    }
}
