import SwiftUI
import AppKit

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, account, deepl, speech, shortcuts, permissions, history, glossary, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: return "外观"
        case .account: return "账号与安全"
        case .deepl: return "了解与帮助"
        case .speech: return "在线朗读"
        case .shortcuts: return "快捷键与划词"
        case .history: return "历史记录"
        case .permissions: return "权限状态"
        case .glossary: return "自定义词库"
        case .about: return "关于与更新"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .account: return "person.crop.circle.badge.checkmark"
        case .deepl: return "book"
        case .speech: return "waveform"
        case .shortcuts: return "keyboard"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield"
        case .glossary: return "text.book.closed"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .appearance: return "让 Yike 符合你的使用习惯"
        case .account: return "登录与管理你的 Yike 账号"
        case .deepl: return "了解翻译引擎、信息处理方式与个人接入"
        case .speech: return "调整声音、语速与本地缓存"
        case .shortcuts: return "自定义快捷键，随时呼出翻译悬浮窗"
        case .history: return "管理文字与图片的本机记录"
        case .permissions: return "检查语音识别和麦克风的访问权限"
        case .glossary: return "让人名、术语与常用表达保持一致"
        case .about: return "查看版本、检查更新与联系我们"
        }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: TranslatorViewModel
    @ObservedObject private var updater = UpdateManager.shared
    var openAccount = false
    @AppStorage("fanyi.appearance.mode") private var appearanceMode = "system"
    @AppStorage("fanyi.glass.enabled") private var glassEnabled = true
    @State private var selectedSection: SettingsSection = .appearance
    @State private var glossarySource = ""
    @State private var showDeepLSettings = false
    @State private var showHistory = false
    @State private var updateCheckResult: UpdateManager.CheckResult?
    @State private var showUpdateResult = false
    @State private var keyButtonHighlighted = false
    @State private var appleButtonHighlighted = false
    @State private var glossaryTarget = ""
    @State private var glossarySourceLanguage = "en"
    @State private var glossaryTargetLanguage = "zh-CN"
    @State private var privateFilesEnabled = SecretStorage.usesPrivateFiles
    @State private var showPrivateFilesConfirmation = false
    @State private var secretStorageMessage = ""

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        return "V \(version)"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Yike").font(.system(size: 17, weight: .semibold))
                        Text("设置").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 10)

                VStack(spacing: 5) {
                    ForEach(SettingsSection.allCases) { section in
                        Button {
                            selectedSection = section
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(width: 28, height: 28)
                                    .foregroundStyle(selectedSection == section ? Color.accentColor : Color.secondary)
                                Text(section.title).font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(selectedSection == section ? Color.accentColor.opacity(0.13) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(section.title)
                        .accessibilityIdentifier("settings." + section.rawValue)
                        .accessibilityAddTraits(selectedSection == section ? [.isSelected] : [])
                    }
                }
                Spacer()
                Text(versionText).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            .padding(14)
            .frame(width: 210)
            .background(.thinMaterial)
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedSection.title).font(.system(size: 21, weight: .semibold))
                        Text(selectedSection.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 26).padding(.vertical, 23)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(selectedSection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 600)
        .background {
            AdaptiveGlassBackdrop(materialOpacity: 0.92, tintOpacity: 0.16)
                .ignoresSafeArea()
        }
        .onAppear {
            if openAccount { selectedSection = .account }
            model.refreshSpeechCacheSize()
            if model.hasDeepLKey { Task { await model.fetchDeepLUsage() } }
        }
        .sheet(isPresented: $showDeepLSettings) {
            DeepLSettingsSheet(model: model, isPresented: $showDeepLSettings)
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(model: model, isPresented: $showHistory)
        }
        .confirmationDialog("改为本机私有文件？", isPresented: $showPrivateFilesConfirmation, titleVisibility: .visible) {
            Button("启用本机保存") {
                do {
                    try SecretStorage.enablePrivateFiles()
                    privateFilesEnabled = true
                    secretStorageMessage = "账号会话和 DeepL 密钥已迁移；以后更新不再读取钥匙串。"
                } catch { secretStorageMessage = "迁移失败：\(error.localizedDescription)；仍使用系统钥匙串。" }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("资料将保存在仅当前 macOS 账户可读的文件中。同一账户运行的其他程序也可能读取；首次迁移可能还需授权钥匙串一次。")
        }
        .alert(updateAlertTitle, isPresented: $showUpdateResult) {
            if updateCheckResult == .available {
                Button("暂不更新", role: .cancel) { }
                Button("立即更新") { Task { await updater.installNow() } }
            } else {
                Button("知道了", role: .cancel) { }
            }
        } message: {
            if updateCheckResult == .available, let update = updater.latest {
                Text("V \(update.version)\n\n\(update.notes)")
            } else if updateCheckResult == .failed {
                Text(updater.status)
            }
        }
        .sheet(isPresented: $updater.showsInstallError) {
            YikeInstallFailureView(updater: updater)
        }
        .sheet(isPresented: $updater.showsProgress) {
            YikeUpdateProgressView(updater: updater)
                .interactiveDismissDisabled(updater.isChecking)
        }
        .task(id: keyButtonHighlighted) {
            guard keyButtonHighlighted else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            keyButtonHighlighted = false
        }
        .task(id: appleButtonHighlighted) {
            guard appleButtonHighlighted else { return }
            do { try await Task.sleep(nanoseconds: 300_000_000) }
            catch { return }
            model.setEngine(.apple)
            dismiss()
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case .appearance:
        settingsCard("显示效果", icon: "paintpalette") {
            Picker("外观", selection: $appearanceMode) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $glassEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("玻璃质感")
                    Text(glassEnabled ? "使用当前半透明毛玻璃界面" : "使用经典不透明界面")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        case .history:
        settingsCard("保存与回看", icon: "clock.arrow.circlepath") {
            Text("按需保留翻译记录，方便之后查看与复用。").font(.system(size: 12)).foregroundStyle(.secondary)
            Button {
                showHistory = true
            } label: {
                Label("查看历史记录", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("settings.openHistory")
            Divider()
            Toggle("保存翻译历史", isOn: Binding(
                get: { model.historyRecordingEnabled },
                set: { model.setHistoryRecording($0) }
            ))
            Toggle("保存最近 10 张图片翻译", isOn: Binding(
                get: { model.imageHistoryRecordingEnabled },
                set: { model.setImageHistoryRecording($0) }
            ))
        }
        case .account:
        AccountSecuritySummary(model: model)
        settingsCard("本机密钥保存", icon: "lock.doc") {
            Text(privateFilesEnabled ? "账号会话和个人 DeepL 密钥保存在本机私有文件，更新后无需重复授权钥匙串。" : "当前保存在系统钥匙串；临时签名的新版可能再次要求授权。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if privateFilesEnabled {
                Button("改回系统钥匙串") {
                    do {
                        try SecretStorage.useKeychain()
                        privateFilesEnabled = false
                        secretStorageMessage = "已改回系统钥匙串。"
                    } catch { secretStorageMessage = "切换失败：\(error.localizedDescription)" }
                }
            } else {
                Button("启用本机保存，免重复授权") { showPrivateFilesConfirmation = true }
            }
            if !secretStorageMessage.isEmpty {
                Text(secretStorageMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        case .deepl:
        if let feedback = model.deepLKeyFeedback { KeySaveFeedbackView(notice: feedback) }
        settingsCard("三种引擎如何工作", icon: "arrow.triangle.branch") {
            engineExplanation("Apple 系统翻译", detail: "调用 macOS 15 及以上的系统翻译能力。首次使用需下载对应语言包，准备完成后在本机处理文字，无需 DeepL 密钥。")
            Divider()
            engineExplanation("DeepL（个人接入）", detail: "使用你自己的 API Free 密钥，将待翻译文字直接发送到 DeepL 在线翻译，消耗个人账号额度。密钥按“账号与安全”中的本机保存方式存放。")
            Divider()
            engineExplanation("DeepL 高质量翻译", detail: "登录 Yike 账号后使用，无需填写个人密钥。待翻译文字通过 Yike 服务转交 DeepL 处理，使用账号可用额度，需要联网。")
            Text("图片先在本机识别文字，再交给所选引擎翻译；翻译记录是否保留，可在“历史记录”中设置。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        settingsCard("个人 DeepL 接入", icon: "key") {
            if let usage = model.deepLUsage {
                LabeledContent("DeepL 免费额度") {
                    Text("剩余 \(max(0, usage.characterLimit - usage.characterCount)) / \(usage.characterLimit) 字符")
                }
            } else {
                LabeledContent("DeepL 免费额度") { Text(model.hasDeepLKey ? "正在读取" : "尚未设置密钥") }
            }
            Divider()
            DeepLKeyHelp()
            HStack {
                Button(model.hasDeepLKey ? "更新 DeepL 密钥" : "填写 DeepL 密钥") {
                    keyButtonHighlighted = true
                    showDeepLSettings = true
                }
                .buttonStyle(SettingsFeedbackButtonStyle(highlighted: keyButtonHighlighted))
                Button("使用免密钥的 Apple 翻译") {
                    appleButtonHighlighted = true
                }
                    .buttonStyle(SettingsFeedbackButtonStyle(highlighted: appleButtonHighlighted))
                    .disabled(ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15)
            }
        }
        case .speech:
        settingsCard("声音与缓存", icon: "speaker.wave.2") {
            HStack {
                Text("语速")
                Slider(value: Binding(
                    get: { Double(model.onlineSpeechRatePercent) },
                    set: { model.setOnlineSpeechRatePercent(Int($0.rounded())) }
                ), in: -30...30, step: 1)
                Text(model.speechRateDisplayText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 46, alignment: .trailing)
            }
            Picker("音色", selection: Binding(
                get: { model.onlineVoicePersona },
                set: { model.setOnlineVoicePersona($0) }
            )) {
                ForEach(OnlineVoicePersona.allCases) { persona in
                    Text(persona.title).tag(persona)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                LabeledContent("语音缓存") { Text(model.speechCacheSizeText) }
                Button("清理缓存") { model.clearSpeechCache() }
            }
        }
        case .permissions:
        settingsCard("语音输入授权", icon: "lock.shield") {
            permissionRow("语音识别", status: model.speechRecognitionPermissionText) {
                NoticeAction.openSpeechRecognitionSettings.open()
            }
            permissionRow("麦克风", status: model.microphonePermissionText) {
                NoticeAction.openMicrophoneSettings.open()
            }
        }
        case .shortcuts:
            SelectionShortcutSettings(model: model)
        case .glossary:
        settingsCard("固定译文", icon: "text.book.closed") {
            HStack(spacing: 10) {
                TextField("原词，例如 OpenAI", text: $glossarySource)
                Image(systemName: "arrow.right")
                    .foregroundStyle(Color.secondary)
                TextField("固定译文，例如 开放人工智能", text: $glossaryTarget)
            }
            HStack {
                languagePicker(selection: $glossarySourceLanguage, excluding: glossaryTargetLanguage)
                Image(systemName: "arrow.right")
                languagePicker(selection: $glossaryTargetLanguage, excluding: glossarySourceLanguage)
                Spacer()
                Button("添加词条") {
                    model.addGlossaryEntry(
                        source: glossarySource,
                        target: glossaryTarget,
                        sourceLanguage: glossarySourceLanguage,
                        targetLanguage: glossaryTargetLanguage
                    )
                    glossarySource = ""
                    glossaryTarget = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(glossarySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || glossaryTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.glossary.isEmpty {
                Text("尚未添加词条。词条会应用到普通翻译和图片翻译。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.glossary.enumerated()), id: \.element.id) { index, entry in
                        HStack {
                            Text("\(languageName(entry.sourceLanguage)) · \(entry.source)")
                            Image(systemName: "arrow.right")
                                .foregroundStyle(Color.secondary)
                            Text("\(languageName(entry.targetLanguage)) · \(entry.target)")
                            Spacer()
                            Button(role: .destructive) {
                                model.deleteGlossaryEntries(at: IndexSet(integer: index))
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 8)
                        if index < model.glossary.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .glassSurface(cornerRadius: 10)
            }
        }
        case .about:
        settingsCard("版本信息", icon: "arrow.triangle.2.circlepath") {
            LabeledContent("当前版本") { Text(versionText) }
            Text("本工具由null团队打造")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button(updater.isChecking ? "正在检查…" : "检查更新") {
                    Task {
                        if let result = await updater.checkNow() {
                            updateCheckResult = result
                            showUpdateResult = true
                        }
                    }
                }
                .disabled(updater.isChecking)
                if updater.showsInstallReady {
                    Button("继续安装") { dismiss(); updater.showsProgress = true }
                }
            }
        }
        settingsCard("联系 Yike", icon: "envelope") {
            HStack(spacing: 12) {
                Text("邮箱").foregroundStyle(.secondary)
                Text("yike141@qq.com")
                    .textSelection(.enabled)
            }
            .font(.system(size: 12))
        }
        settingsCard("退出应用", icon: "power") {
            HStack {
                Text("关闭所有 Yike 窗口，停止菜单栏与全局快捷键。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("退出 Yike") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NSApp.terminate(nil)
                    }
                }
                    .accessibilityIdentifier("settings.quit")
                    .buttonStyle(.bordered)
            }
        }
        }
    }

    private var updateAlertTitle: String {
        switch updateCheckResult {
        case .current: return "当前为最新版"
        case .available: return "检查到新版本"
        case .failed: return "检查更新失败"
        case nil: return "检查更新"
        }
    }

    private func settingsCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Label(title, systemImage: icon)
                    .font(.system(size: 15, weight: .semibold))
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
    }

    private func engineExplanation(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ title: String, status: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(status, systemImage: status == "已允许" ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(status == "已允许" ? Color.green : Color.orange)
            Button("系统设置") { action() }
        }
        .font(.system(size: 12))
    }

    private func languagePicker(selection: Binding<String>, excluding: String) -> some View {
        Picker("", selection: selection) {
            ForEach(concreteLanguages.filter { $0 != excluding }, id: \.self) { code in
                Text(languageName(code)).tag(code)
            }
        }
        .labelsHidden()
        .frame(width: 120)
    }
}

private struct SettingsFeedbackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        let active = isEnabled && (highlighted || configuration.isPressed)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(active ? Color.blue : Color.primary)
            .background(active ? Color.blue.opacity(0.15) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(active ? Color.blue.opacity(0.5) : Color.primary.opacity(0.12), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
