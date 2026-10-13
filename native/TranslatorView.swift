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

struct TranslatorView: View {
    @StateObject private var model = TranslatorViewModel.shared
    @ObservedObject private var profile = UserProfile.shared
    @ObservedObject private var trialAccount = SharedTrialAccount.shared
    @ObservedObject private var updater = UpdateManager.shared
    @AppStorage("fanyi.appearance.mode") private var appearanceMode = "system"
    @AppStorage("fanyi.glass.enabled") private var glassEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var showHistory = false
    @State private var showEnginePicker = false
    @State private var showDeepLSettings = false
    @State private var isImageDropTargeted = false
    @State private var imagePreview: ImagePreviewItem?
    @State private var showImageComparison = false
    @State private var showImageEditor = false
    @State private var showSettings = false
    private let accent = MacVisualTokens.accent
    private let success = Color(nsColor: .systemGreen)
    private var effectiveDarkMode: Bool { colorScheme == .dark }
    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    private var appearanceModeLabel: String {
        switch appearanceMode {
        case "light": return "浅色"
        case "dark": return "深色"
        default: return "跟随系统"
        }
    }
    private var ink: Color { MacVisualTokens.label }
    private var line: Color { MacVisualTokens.separator.opacity(effectiveDarkMode ? 0.78 : 0.62) }
    private var surface: Color { MacVisualTokens.controlFill }
    /// All non-editor surfaces use the same material strength and tint.  Keeping
    /// this in one place prevents the left/right panes and the header/footer from
    /// drifting into visibly different glass tones.
    // A shared semi-transparent strength for every glass surface.  The same
    // value is used in light and dark mode so the title bar and content panes
    // keep one consistent translucency level.
    private let glassMaterialOpacity = 0.88
    private var glassTint: Color {
        effectiveDarkMode ? Color.black.opacity(0.32) : Color.white.opacity(0.32)
    }
    private var windowTint: Color { glassTint }
    private var editorTint: Color {
        Color.clear
    }

    var body: some View {
        ZStack {
            UnifiedGlassLayer(
                tint: windowTint,
                materialOpacity: glassMaterialOpacity,
                isUltraThin: false,
                isRegular: true
            )
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if updater.showsUpdateComplete || updater.phase == .starting {
                    updateStatusBanner
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                }
                translatorCard
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 22)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 934, minHeight: 560)
        .preferredColorScheme(preferredScheme)
        .overlay(alignment: .top) {
            if let feedback = model.deepLKeyFeedback { KeySaveFeedbackView(notice: feedback) }
        }
        .onAppear {
            migrateAppearanceIfNeeded()
            applyAppearance()
            Task {
                // SwiftUI's first onAppear can precede the AppKit window becoming key.
                try? await Task.sleep(for: .seconds(1))
                await updater.checkIfNeeded()
                if updater.showsUpdateComplete { return }
                try? await Task.sleep(for: .milliseconds(350))
                model.loadKeyAfterLaunch()
                trialAccount.restoreSessionAfterLaunch()
            }
        }
        .onChange(of: updater.showsUpdateComplete) { presented in
            if !presented {
                model.loadKeyAfterLaunch()
                trialAccount.restoreSessionAfterLaunch()
            }
        }
        .onChange(of: appearanceMode) { _ in applyAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.hasDeepLKey {
                Task { await model.fetchDeepLUsage() }
            }
        }
        .overlay(alignment: .topLeading) {
            if #available(macOS 15.0, *) {
                AppleTranslationWorker(model: model)
            }
        }
        .sheet(item: $model.pendingImageCrop) { item in
            ImageCropSheet(item: item, cancel: { model.pendingImageCrop = nil }, confirm: { model.finishImageCrop(item, selection: $0) })
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(model: model, isPresented: $showHistory)
        }
        .sheet(isPresented: $model.showSharedAccount) {
            SettingsSheet(model: model, openAccount: true)
        }
        .sheet(isPresented: $model.showVoiceModelDownload) {
            VStack(alignment: .leading, spacing: 16) {
                Label("启用语音自动检测", systemImage: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                Text("首次下载约 148MB 的多语言语音模型，之后可在本机自动识别，无需密钥。录音不会上传到翻译服务；识别后点击翻译时按所选翻译引擎处理文字。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text("自动模式录音结束后显示文字；手动选择语言可使用系统实时识别。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button("暂不下载") { model.showVoiceModelDownload = false }
                    Spacer()
                    Button("下载并开始录音", action: model.downloadVoiceModelAndStart)
                        .buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 450)
        }
        .sheet(isPresented: $showDeepLSettings) {
            DeepLSettingsSheet(model: model, isPresented: $showDeepLSettings)
        }
        .sheet(item: $imagePreview) { item in
            ImagePreviewSheet(item: item)
        }
        .sheet(isPresented: $model.isEditingImageOCR) {
            if let source = model.sourceImage {
                ImageOCRReviewSheet(
                    model: model,
                    source: source,
                    blocks: model.imageOCRBlocksForEditing()
                )
            }
        }
        .sheet(isPresented: $showImageComparison) {
            if let source = model.sourceImage, let translated = model.translatedImage {
                ImageComparisonSheet(source: source, translated: translated)
            }
        }
        .sheet(isPresented: $showImageEditor) {
            if let source = model.sourceImage {
                ImageTranslationEditorSheet(
                    source: source,
                    blocks: model.editableImageBlocks,
                    resetBlocks: model.resetImageEdits(),
                    onApply: model.applyImageEdits
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openYikeSettings)) { _ in showSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .translateSelectedText)) { notification in
            let processID = (notification.userInfo?["pid"] as? Int).map(pid_t.init)
            model.translateSelectedText(from: processID)
        }
        .alert("检查到新版本", isPresented: $updater.showsUpdateAlert) {
            Button("暂不更新") { }
            Button("立即更新") { Task { await updater.installNow() } }
        } message: {
            if let update = updater.latest {
                Text("\(update.title)\n\n\(update.notes)")
            }
        }
        .sheet(isPresented: $updater.showsInstallError) {
            YikeInstallFailureView(updater: updater)
        }
        .sheet(isPresented: Binding(
            get: { updater.showsProgress && !showSettings && !model.showSharedAccount },
            set: { if !$0 { updater.showsProgress = false } }
        )) {
            YikeUpdateProgressView(updater: updater)
                .interactiveDismissDisabled(updater.isChecking)
        }
    }

    private var updateStatusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: updater.phase == .failed ? "exclamationmark.triangle" : "checkmark.circle.fill")
            Text(updater.showsUpdateComplete
                 ? "更新完毕。首次迁移账号或密钥时，macOS 可能请求钥匙串授权。"
                 : updater.phase == .starting ? "正在启动 Yike…" : updater.status)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            if updater.showsUpdateComplete {
                Button("知道了") { updater.showsUpdateComplete = false }
            }
        }
        .foregroundStyle(MacVisualTokens.accent)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack {
            Button { model.showSharedAccount = true } label: {
                HStack(spacing: 12) {
                    ProfileAvatar(email: trialAccount.account?.email, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trialAccount.account?.email.map { profile.name($0) } ?? "未登录")
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(ink)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            TranslationEngineMark(engine: model.selectedEngine)
                            Text(engineStatusText)
                        }.font(.system(size: 12)).foregroundStyle(MacVisualTokens.secondaryLabel)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("账号与安全")
            Spacer()
            HStack(spacing: 8) {
                Button { showEnginePicker.toggle() } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.selectedEngine == .apple ? accent : success)
                            .frame(width: 7, height: 7)
                        Text(model.selectedEngine.shortName)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(MacVisualTokens.tertiaryLabel)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ink)
                    .macHoverControl(horizontalPadding: 10, height: 36)
                }
                .task(id: model.selectedEngine) {
                    if model.selectedEngine == .sharedDeepL { await trialAccount.refresh() }
                    else if model.selectedEngine == .deepl { await model.fetchDeepLUsage() }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showEnginePicker, arrowEdge: .bottom) { enginePicker }
                .fixedSize()

                Button(action: { showHistory = true }) {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 14, weight: .medium))
                        Text("历史记录")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ink)
                    .macHoverControl(horizontalPadding: 10, height: 36)
                }
                .buttonStyle(.plain)

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ink)
                        .macHoverControl(cornerRadius: 9, horizontalPadding: 0, height: 36)
                        .frame(width: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
                .accessibilityIdentifier("openSettings")
                .help("设置")
            }
        }
        .padding(.leading, 48)
        .padding(.trailing, 24)
        .padding(.top, 5)
        .frame(maxWidth: .infinity)
        .frame(height: 78)
        .overlay(alignment: .bottom) {
            Rectangle().fill(line).frame(height: 0.5)
        }
    }

    private var translatorCard: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    LanguageMenu(color: accent, textColor: ink, selection: model.sourceLanguage, options: sourceLanguagesWithAuto, onChange: model.setSourceLanguage)
                    Spacer()
                    LanguageMenu(color: accent, textColor: ink, selection: model.targetLanguage, onChange: model.setTargetLanguage)
                }

                Button(action: model.swapLanguages) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(accent.opacity(0.72))
                        .frame(width: 40, height: 40)
                }
                    .buttonStyle(LanguageSwapButtonStyle())
                    .disabled(model.hasImageTranslation)
                    .opacity(model.hasImageTranslation ? 0.42 : 1)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)

            Rectangle().fill(line).frame(height: 0.5)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        if let sourceImage = model.sourceImage {
                            TranslationImagePane(image: sourceImage, title: "原图", accent: accent) {
                                imagePreview = ImagePreviewItem(title: "原图", image: sourceImage)
                            }
                            .contextMenu {
                                Button(action: model.editImageSourceText) {
                                    Label("编辑原图文字", systemImage: "text.viewfinder")
                                }
                                .disabled(!model.canEditImageSourceText)
                                Button {
                                    imagePreview = ImagePreviewItem(title: "原图", image: sourceImage)
                                } label: {
                                    Label("放大查看", systemImage: "arrow.up.left.and.arrow.down.right")
                                }
                            }

                            VStack {
                                HStack {
                                    Button(action: model.editImageSourceText) {
                                        Label("编辑原图文字", systemImage: "text.viewfinder")
                                            .font(.system(size: 11, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .frame(height: 30)
                                            .glassSurface(cornerRadius: 8)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(ink)
                                    .disabled(!model.canEditImageSourceText)
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(12)
                        } else {
                            SubmitTextEditor(text: Binding(
                                get: { model.sourceText },
                                set: { model.sourceText = String($0.prefix(maxSourceCharacters)) }
                            ), isDarkMode: effectiveDarkMode, onSubmit: model.handleReturnKey, onImageDrop: model.recognizeAndTranslateImage)
                            .background(editorTint)
                        }

                        if model.isRecognizingImage || model.isCapturingRegion {
                            VStack(spacing: 12) {
                                ProgressView().controlSize(.regular)
                                Text(model.isCapturingRegion
                                     ? (model.screenCaptureCountdown > 0
                                        ? "请切换到目标窗口，\(model.screenCaptureCountdown) 秒后开始框选…"
                                        : "请在屏幕上框选要翻译的区域…")
                                     : "正在识别图片中的文字…")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("支持英语、中文、日语、韩语、德语和法语")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                AdaptiveGlassBackdrop(materialOpacity: 0.96, tintOpacity: 0.18)
                            }
                        } else if model.sourceImage == nil && model.sourceText.isEmpty {
                            EditorEmptyState(title: inputPlaceholder, imageHint: imageDropHint)
                        }
                    }
                    HStack {
                        if model.sourceLanguage == "auto", let detected = model.detectedVoiceLanguage {
                            Text("语音识别：\(languageName(detected))")
                                .font(.system(size: 11)).foregroundStyle(accent)
                        }
                        Spacer()
                        Text(model.hasImageTranslation ? "图片原文 · \(model.sourceText.count) 字符" : "\(model.sourceText.count) / \(maxSourceCharacters)")
                            .font(.system(size: 11))
                            .foregroundStyle(MacVisualTokens.tertiaryLabel)
                    }
                    .padding(.horizontal, 28).frame(height: 42)
                }
                .frame(maxWidth: .infinity)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isImageDropTargeted, perform: handleImageDrop)
                .overlay {
                    if isImageDropTargeted {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(accent.opacity(0.09))
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(accent, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                            VStack(spacing: 10) {
                                Image(systemName: "photo.badge.arrow.down")
                                    .font(.system(size: 34, weight: .medium))
                                Text("松开鼠标，开始翻译图片")
                                    .font(.system(size: 15, weight: .medium))
                                Text("支持英语、中文、日语、韩语、德语和法语")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(accent)
                        }
                        .padding(10)
                        .allowsHitTesting(false)
                    }
                }

                Rectangle()
                    .fill(glassEnabled
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color.white.opacity(effectiveDarkMode ? 0.36 : 0.90),
                                     MacVisualTokens.separator.opacity(0.40),
                                     Color.white.opacity(effectiveDarkMode ? 0.08 : 0.20)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        : AnyShapeStyle(line))
                    .frame(width: 0.8)

                VStack(spacing: 0) {
                    Group {
                        if model.isLoading {
                            VStack(spacing: 12) {
                                ProgressView().controlSize(.regular)
                                Text(model.translationProgress)
                                Button("取消翻译", action: model.cancelTranslation)
                            }
                                .font(.system(size: 12)).foregroundStyle(Color.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let diagnostic = model.notice?.diagnostic {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    TranslationDiagnosticView(diagnostic: diagnostic)
                                    HStack(spacing: 12) {
                                        Button("重新尝试", action: model.translate)
                                            .disabled(!model.canTranslate)
                                        if diagnostic.engine == .deepl || !model.hasDeepLKey {
                                            Button("设置 DeepL 密钥") { showDeepLSettings = true }
                                        }
                                    }
                                    Button(model.selectedEngine == .apple ? "切换到 DeepL" : "切换到 Apple 翻译") {
                                        if model.selectedEngine == .apple && !model.hasDeepLKey {
                                            showDeepLSettings = true
                                        } else {
                                            model.setEngine(model.selectedEngine == .apple ? .deepl : .apple)
                                            model.translate()
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .padding(24)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else if let notice = model.notice {
                            VStack(spacing: 12) {
                                Image(systemName: notice.kind.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(notice.kind.color)
                                    .frame(width: 34, height: 34)
                                    .background(notice.kind.color.opacity(0.12))
                                    .clipShape(Circle())
                                Text(notice.message).font(.system(size: 12)).foregroundStyle(Color.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 360)
                                HStack(spacing: 12) {
                                    if let action = notice.action {
                                        Button(action.buttonTitle) { action.open() }.buttonStyle(.bordered)
                                    }
                                    if notice.kind == .error {
                                        Button(notice.retryVoiceModelDownload ? "重新下载" : "重新尝试") {
                                            if notice.retryVoiceModelDownload { model.downloadVoiceModelAndStart() }
                                            else { model.translate() }
                                        }.buttonStyle(.bordered)
                                        if model.hasImageTranslation {
                                            Button("换引擎重试") {
                                                model.setEngine(model.selectedEngine == .apple ? .deepl : .apple)
                                                model.translate()
                                            }.buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let translatedImage = model.translatedImage {
                            TranslationImagePane(image: translatedImage, title: "译文图片 · \(model.imageRenderStyle.title)", accent: accent) {
                                imagePreview = ImagePreviewItem(title: "译文图片 · \(model.imageRenderStyle.title)", image: translatedImage)
                            }
                        } else {
                            ZStack(alignment: .topLeading) {
                                ResultTextEditor(text: Binding(get: { model.translatedText }, set: model.editTranslatedText),
                                                 isVoiceActive: model.isListening || model.isVoiceProcessing,
                                                 onVoiceReturn: model.handleReturnKey)
                                if model.translatedText.isEmpty {
                                    EditorEmptyState(title: "译文显示在这", symbol: "text.bubble")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 300, maxHeight: .infinity)
            .background {
                AdaptiveGlassBackdrop(materialOpacity: 0.96, tintOpacity: 0.18)
            }
            .overlay {
                Rectangle()
                    .stroke(glassEnabled
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color.white.opacity(effectiveDarkMode ? 0.40 : 0.94),
                                     MacVisualTokens.separator.opacity(0.38),
                                     Color.white.opacity(effectiveDarkMode ? 0.10 : 0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        : AnyShapeStyle(line),
                        lineWidth: 0.8)
                    .allowsHitTesting(false)
            }

            Rectangle().fill(line).frame(height: 0.5)

            if model.isListening || model.isVoiceProcessing {
                VoiceInputBar(level: model.microphoneLevel, status: model.voiceInputStatus,
                              countdown: model.voiceSilenceCountdown,
                              isRecording: model.isListening, stop: model.stopListening,
                              cancel: model.cancelVoiceSubmission)
            } else {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button(action: model.toggleListening) {
                        Label(model.isListening ? "停止录音" : "语音输入", systemImage: model.isListening ? "stop.circle.fill" : "mic")
                    }
                    .foregroundStyle(model.isListening ? Color(nsColor: .systemRed) : ink)
                    Divider().frame(height: 18)
                    Button(action: chooseImage) {
                        Label("翻译图片", systemImage: "photo")
                    }
                    .disabled(model.isRecognizingImage || model.isCapturingRegion)
                    Divider().frame(height: 18)
                    Button(action: model.captureScreenRegionAndTranslate) {
                        Label("截图翻译", systemImage: "viewfinder")
                    }
                    .disabled(model.isRecognizingImage || model.isCapturingRegion || model.isLoading)
                    .help("点击后有 3 秒切换到目标窗口，然后拖动框选")
                    Divider().frame(height: 18)
                    Button(action: {
                        if confirmYikeAction("清空当前内容？", detail: "当前输入、译文和图片将被清空。", action: "确认清空") { model.clear() }
                    }) {
                        Label("清空", systemImage: "trash")
                    }
                    .disabled(model.sourceText.isEmpty && model.translatedText.isEmpty && !model.hasImageTranslation)
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.borderless)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: model.translate) {
                    HStack(spacing: 12) {
                        Text(model.isLoading ? "翻译中" : (model.hasImageTranslation ? "重新翻译图片" : "开始翻译"))
                        Text("Enter")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.42), lineWidth: 0.5))
                    }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 174, height: 40)
                        .foregroundStyle(model.canTranslate ? Color.white : ink.opacity(0.62))
                        .background {
                            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                            ZStack {
                                if glassEnabled {
                                    shape.fill(.regularMaterial).opacity(0.94)
                                }
                                shape.fill(
                                    model.canTranslate
                                        ? (glassEnabled
                                            ? AnyShapeStyle(LinearGradient(
                                                colors: [accent.opacity(0.80),
                                                         accent.opacity(0.56)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ))
                                            : AnyShapeStyle(accent))
                                        : AnyShapeStyle(accent.opacity(effectiveDarkMode ? 0.16 : 0.09))
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(glassEnabled
                                    ? AnyShapeStyle(LinearGradient(
                                        colors: [Color.white.opacity(model.canTranslate
                                            ? (effectiveDarkMode ? 0.40 : 0.82)
                                            : (effectiveDarkMode ? 0.20 : 0.38)),
                                                 accent.opacity(model.canTranslate ? 0.40 : 0.24)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    : AnyShapeStyle(line),
                                    lineWidth: 0.8)
                        }
                        .shadow(
                            color: glassEnabled ? accent.opacity(model.canTranslate ? 0.18 : 0) : Color.clear,
                            radius: glassEnabled ? 10 : 0,
                            y: glassEnabled ? 4 : 0
                        )
                }
                .buttonStyle(TranslationActionButtonStyle()).disabled(!model.canTranslate)
                .keyboardShortcut(.return, modifiers: [])

                HStack(spacing: 10) {
                    if model.hasImageTranslation {
                        Menu {
                            Section("译图效果") {
                                ForEach(ImageTranslationRenderStyle.allCases) { style in
                                    Button {
                                        model.setImageRenderStyle(style)
                                    } label: {
                                        Label(style.title, systemImage: model.imageRenderStyle == style ? "checkmark" : style.icon)
                                    }
                                }
                            }
                            Divider()
                            Button {
                                showImageComparison = true
                            } label: {
                                Label("原图 / 译图对比", systemImage: "slider.horizontal.below.rectangle")
                            }
                            .disabled(model.translatedImage == nil)
                            Button(action: model.editImageSourceText) {
                                Label("编辑原图文字", systemImage: "text.viewfinder")
                            }
                            .disabled(!model.canEditImageSourceText)
                            Button {
                                showImageEditor = true
                            } label: {
                                Label("编辑译文框", systemImage: "rectangle.and.pencil.and.ellipsis")
                            }
                            .disabled(model.translatedImage == nil || model.editableImageBlocks.isEmpty)
                            Divider()
                            Button(action: model.copyTranslatedImage) {
                                Label(model.imageActionLabel, systemImage: "photo.on.rectangle")
                            }
                            .disabled(model.translatedImage == nil)
                            Button(action: model.saveTranslatedImage) {
                                Label("保存图片…", systemImage: "square.and.arrow.down")
                            }
                            .disabled(model.translatedImage == nil)
                        } label: {
                            Label("图片工具", systemImage: "ellipsis.circle")
                                .foregroundStyle(ink)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else {
                        if let status = model.speechStatusMessage {
                            Text(status).lineLimit(1)
                            Divider().frame(height: 18)
                        }
                        Menu {
                            ForEach(OnlineVoicePersona.allCases) { persona in
                                Button {
                                    model.setOnlineVoicePersona(persona)
                                } label: {
                                    if model.onlineVoicePersona == persona {
                                        Label(persona.title, systemImage: "checkmark")
                                    } else {
                                        Text(persona.title)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: model.onlineVoicePersona.icon)
                                Text(model.onlineVoicePersona.title)
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(ink)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Divider().frame(height: 18)
                        Button(action: model.speakResult) {
                            Label(resultSpeechButtonTitle, systemImage: resultSpeechButtonIcon)
                        }
                        .disabled(model.translatedText.isEmpty)
                        Divider().frame(height: 18)
                        Button(action: model.copyResult) {
                            Label(model.copyLabel, systemImage: "doc.on.doc")
                        }
                        .disabled(model.translatedText.isEmpty)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.borderless)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            }
        }
        .background {
            AdaptiveGlassBackdrop(materialOpacity: 0.84, tintOpacity: 0.07, regular: false)
        }
        .clipShape(RoundedRectangle(cornerRadius: MacVisualTokens.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MacVisualTokens.panelRadius, style: .continuous)
                .stroke(glassEnabled
                    ? AnyShapeStyle(LinearGradient(
                        colors: [Color.white.opacity(effectiveDarkMode ? 0.36 : 0.92),
                                 Color.white.opacity(effectiveDarkMode ? 0.12 : 0.30),
                                 MacVisualTokens.separator.opacity(0.46)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    : AnyShapeStyle(line),
                    lineWidth: 0.9)
        }
        .shadow(
            color: glassEnabled ? Color.black.opacity(effectiveDarkMode ? 0.20 : 0.10) : Color.black.opacity(0.05),
            radius: glassEnabled ? 18 : 4,
            y: glassEnabled ? 8 : 1
        )
        .frame(maxWidth: 1120, maxHeight: .infinity)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择要翻译的图片"
        panel.message = "支持英语、中文、日语、韩语、德语和法语"
        panel.prompt = "翻译图片"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.recognizeAndTranslateImage(at: panel.urls[0])
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let directURL = item as? URL {
                url = directURL
            } else if let nsURL = item as? NSURL {
                url = nsURL as URL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }

            Task { @MainActor in
                guard let url else {
                    model.notice = AppNotice(kind: .error, message: "无法读取拖入的图片，请使用“识别图片”按钮重试")
                    return
                }
                model.recognizeAndTranslateImage(at: url)
            }
        }
        return true
    }

    private var resultSpeechButtonTitle: String {
        if model.isPreparingSpeech { return "停止准备" }
        if model.isResultSpeechPaused { return "继续" }
        if model.isSpeakingResult { return "暂停" }
        return "朗读"
    }

    private var resultSpeechButtonIcon: String {
        if model.isPreparingSpeech { return "xmark.circle" }
        if model.isResultSpeechPaused { return "play.fill" }
        if model.isSpeakingResult { return "pause.fill" }
        return "speaker.wave.2"
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            engineChoice(.apple, symbol: "apple.logo")
            engineChoice(.sharedDeepL, symbol: "sparkles")
            engineChoice(.deepl, symbol: "key")
            if model.selectedEngine != .apple {
                Divider().padding(.vertical, 8)
                if model.selectedEngine == .sharedDeepL {
                    if let current = trialAccount.account {
                        QuotaUsageView(title: "体验额度", used: current.used, total: current.granted)
                    } else {
                        Text(trialAccount.isSignedIn ? "正在获取体验额度…" : "登录后查看体验额度")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Button("账号与安全") { showEnginePicker = false; model.showSharedAccount = true }
                        .padding(.top, 9)
                } else {
                    if let usage = model.deepLUsage {
                        QuotaUsageView(title: "个人额度", used: usage.characterCount, total: usage.characterLimit)
                    } else { Text("个人额度暂未获取").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Button(model.hasDeepLKey ? "更新 DeepL 密钥" : "设置 DeepL 密钥") {
                        showEnginePicker = false; showDeepLSettings = true
                    }.padding(.top, 9)
                }
            }
        }
        .buttonStyle(.plain).padding(16).frame(width: 304)
        .task {
            if model.selectedEngine == .sharedDeepL { await trialAccount.refresh() }
            else if model.selectedEngine == .deepl { await model.fetchDeepLUsage() }
        }
    }

    private func engineChoice(_ engine: TranslationEngine, symbol: String) -> some View {
        Button {
            showEnginePicker = false
            if engine == .deepl && !model.hasDeepLKey { showDeepLSettings = true; return }
            model.setEngine(engine)
            if engine == .sharedDeepL && !trialAccount.isSignedIn { model.showSharedAccount = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(engine.name).font(.system(size: 13))
                Spacer()
                if model.selectedEngine == engine { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }.padding(.horizontal, 9).frame(height: 36)
                .background(model.selectedEngine == engine ? Color.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.accessibilityLabel(engine.name)
    }

    private var engineStatusText: String {
        switch model.selectedEngine {
        case .apple: return "Apple 系统本机翻译"
        case .deepl: return "内容由 DeepL 在线处理"
        case .sharedDeepL: return "由Yike服务器交由DeepL处理"
        }
    }

    private var inputPlaceholder: String {
        switch model.sourceLanguage {
        case "auto": return "输入任意语言，自动检测…"
        case "en": return "在这里输入英文…"
        case "zh-CN": return "在这里输入中文…"
        case "ja": return "在这里输入日文…"
        case "ko": return "在这里输入韩文…"
        case "de": return "在这里输入德文…"
        case "fr": return "在这里输入法文…"
        default: return "在这里输入文字…"
        }
    }

    private var imageDropHint: String {
        switch model.sourceLanguage {
        case "auto": return "也可以把图片拖到这里"
        case "en": return "也可以把英文图片拖到这里"
        case "zh-CN": return "也可以把中文图片拖到这里"
        case "ja": return "也可以把日文图片拖到这里"
        case "ko": return "也可以把韩文图片拖到这里"
        case "de": return "也可以把德文图片拖到这里"
        case "fr": return "也可以把法文图片拖到这里"
        default: return "也可以把图片拖到这里"
        }
    }

    private func shortLanguage(_ code: String) -> String {
        switch code {
        case "en": return "EN"
        case "zh-CN": return "中"
        case "ja": return "日"
        case "ko": return "韩"
        case "de": return "德"
        case "fr": return "法"
        default: return code
        }
    }

    private func applyAppearance() {
        switch appearanceMode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    private func migrateAppearanceIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "fanyi.appearance.mode") == nil,
              defaults.object(forKey: "fanyi.appearance.dark") != nil else { return }
        appearanceMode = defaults.bool(forKey: "fanyi.appearance.dark") ? "dark" : "light"
    }
}
