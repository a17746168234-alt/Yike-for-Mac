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

struct HistorySheet: View {
    private enum HistoryKind: String, CaseIterable, Identifiable {
        case text
        case image
        var id: String { rawValue }
        var title: String { self == .text ? "文字" : "图片" }
    }

    @ObservedObject var model: TranslatorViewModel
    @Binding var isPresented: Bool
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var historyKind: HistoryKind = .text
    private let purple = MacVisualTokens.accent
    private let line = MacVisualTokens.separator.opacity(0.68)

    private var filteredHistory: [TranslationHistory] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.history }
        return model.history.filter {
            $0.original.lowercased().contains(query) || $0.result.lowercased().contains(query)
        }
    }

    private var visibleSelectedIDs: Set<UUID> {
        HistorySelection.visible(selectedIDs, ids: filteredHistory.map(\.id))
    }
    private var allVisibleSelected: Bool {
        !filteredHistory.isEmpty && visibleSelectedIDs.count == filteredHistory.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("历史记录", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                if historyKind == .text && !model.history.isEmpty {
                    if isSelecting {
                        Button(allVisibleSelected ? "取消全选" : "全选") {
                            selectedIDs = HistorySelection.toggleAll(selectedIDs, ids: filteredHistory.map(\.id))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        Button("删除所选（\(visibleSelectedIDs.count)）") {
                            guard confirmYikeAction("删除所选记录？", detail: "将删除所选的 \(visibleSelectedIDs.count) 条记录，无法撤销。", action: "确认删除") else { return }
                            model.deleteHistory(ids: visibleSelectedIDs)
                            selectedIDs = []
                            isSelecting = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .foregroundStyle(Color.red)
                        .disabled(visibleSelectedIDs.isEmpty)
                    } else {
                        Button("多选") { isSelecting = true }
                            .buttonStyle(.bordered)
                        .controlSize(.regular)
                        Button("清空全部") {
                            if confirmYikeAction("清空全部文字历史？", detail: "包括置顶记录，清空后无法恢复。", action: "确认清空") { model.clearHistory() }
                        }
                            .buttonStyle(.bordered)
                        .controlSize(.regular)
                            .foregroundStyle(Color.red.opacity(0.8))
                    }
                } else if historyKind == .image && !model.imageHistory.isEmpty {
                    Button("清空图片历史") {
                        if confirmYikeAction("清空全部图片历史？", detail: "将删除本机保存的原图和译图历史，无法撤销。", action: "确认清空") { model.clearImageHistory() }
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .foregroundStyle(Color.red.opacity(0.8))
                }
                Button(isSelecting ? "取消" : "完成") {
                    if isSelecting {
                        isSelecting = false
                        selectedIDs = []
                    } else {
                        isPresented = false
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(purple)
            }
            .controlSize(.regular)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 22)
            .frame(height: 62)
            .background {
                AdaptiveGlassBackdrop(materialOpacity: 0.78, tintOpacity: 0.14, regular: false)
            }

            Picker("历史类型", selection: $historyKind) {
                ForEach(HistoryKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.bottom, 12)
            .onChange(of: historyKind) { _ in
                isSelecting = false
                selectedIDs = []
            }

            if historyKind == .text && !model.history.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.secondary)
                    TextField("搜索原文或译文…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .glassSurface(cornerRadius: 10)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
            }

            Divider()
                .onChange(of: searchText) { _ in selectedIDs = visibleSelectedIDs }
                .onChange(of: filteredHistory.map(\.id)) { _ in selectedIDs = visibleSelectedIDs }

            if historyKind == .image {
                imageHistoryContent
            } else if model.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(purple.opacity(0.65))
                    Text("还没有翻译记录")
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.historyRecordingEnabled ? "完成一次翻译后，记录会自动保存在本机。" : "历史记录已关闭，可在设置菜单中重新开启。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredHistory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(purple.opacity(0.6))
                    Text("没有匹配「\(searchText)」的记录")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredHistory) { item in
                            HStack(alignment: .top, spacing: 12) {
                                if isSelecting {
                                    Button {
                                        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                                        else { selectedIDs.insert(item.id) }
                                    } label: {
                                        Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 19))
                                            .foregroundStyle(selectedIDs.contains(item.id) ? purple : Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 2)
                                }

                                VStack(alignment: .leading, spacing: 9) {
                                    HStack(spacing: 8) {
                                        Text("\(languageName(item.source)) → \(languageName(item.target))")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(purple)
                                        if !item.engine.isEmpty {
                                            Text(item.engine)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(Color.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.12))
                                                .clipShape(Capsule())
                                        }
                                        Spacer()
                                        Text(historyTimeText(item.date))
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.secondary)
                                        Button {
                                            model.togglePin(item)
                                        } label: {
                                            Image(systemName: item.isPinned ? "pin.fill" : "pin")
                                                .font(.system(size: 11))
                                                .foregroundStyle(item.isPinned ? purple : Color.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help(item.isPinned ? "取消置顶" : "置顶")
                                    }
                                    Text(item.original)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(2)
                                    Text(item.result)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.secondary)
                                        .lineLimit(2)
                                    HStack(spacing: 16) {
                                        Button { model.copyHistoryOriginal(item) } label: {
                                            Label("复制原文", systemImage: "doc.on.doc")
                                        }
                                        Button { model.copyHistoryResult(item) } label: {
                                            Label("复制译文", systemImage: "doc.on.doc.fill")
                                        }
                                        Spacer()
                                        if !isSelecting {
                                            Button("在主界面打开") {
                                                model.use(item)
                                                isPresented = false
                                            }
                                        }
                                        Button(role: .destructive) {
                                            guard confirmYikeAction("删除这条记录？", detail: "删除后无法恢复。", action: "确认删除") else { return }
                                            model.deleteHistory(ids: [item.id])
                                            selectedIDs.remove(item.id)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .buttonStyle(.borderless)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(16)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard isSelecting else { return }
                                if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                                else { selectedIDs.insert(item.id) }
                            }
                            .glassSurface(cornerRadius: 13)
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(item.isPinned ? purple.opacity(0.45) : line))
                        }
                    }
                    .padding(20)
                }
                .background(Color.clear)
            }
        }
        .frame(width: 680, height: 560)
        .background {
            AdaptiveGlassBackdrop(materialOpacity: 0.92, tintOpacity: 0.24)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var imageHistoryContent: some View {
        if model.imageHistory.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 30))
                    .foregroundStyle(purple.opacity(0.65))
                Text("还没有图片翻译记录")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.imageHistoryRecordingEnabled
                    ? "完成图片翻译后，最近 10 张会保存在本机。"
                    : "图片历史已关闭，可在设置中重新开启。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.imageHistory) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                historyThumbnail(model.imageHistoryImage(item, translated: false), label: "原图")
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(Color.secondary)
                                historyThumbnail(model.imageHistoryImage(item, translated: true), label: "译图")
                            }
                            HStack {
                                Label("\(languageName(item.source)) → \(languageName(item.target))", systemImage: "globe")
                                    .foregroundStyle(purple)
                                Text("· \(item.engine) · \(item.style.title)")
                                    .foregroundStyle(Color.secondary)
                                Spacer()
                                Text(historyTimeText(item.date))
                                    .foregroundStyle(Color.secondary)
                            }
                            .font(.system(size: 11, weight: .medium))
                            HStack {
                                Text(item.translatedText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button("在主界面打开") {
                                    model.use(item)
                                    isPresented = false
                                }
                                Button(role: .destructive) {
                                    guard confirmYikeAction("删除这条图片记录？", detail: "将删除对应的原图和译图历史，无法撤销。", action: "确认删除") else { return }
                                    model.deleteImageHistory(ids: [item.id])
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(14)
                        .glassSurface(cornerRadius: 13)
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(line))
                    }
                }
                .padding(20)
            }
            .background(Color.clear)
        }
    }

    private func historyThumbnail(_ image: NSImage?, label: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                Color.secondary.opacity(0.10)
                Image(systemName: "photo")
                    .foregroundStyle(Color.secondary)
            }
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.58))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct DeepLSettingsSheet: View {
    @ObservedObject var model: TranslatorViewModel
    @Binding var isPresented: Bool
    @State private var apiKey: String
    private let purple = MacVisualTokens.accent

    init(model: TranslatorViewModel, isPresented: Binding<Bool>) {
        self.model = model
        self._isPresented = isPresented
        self._apiKey = State(initialValue: SecureKeyStore.loadDeepLKey())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("设置 DeepL API Free")
                        .font(.system(size: 19, weight: .semibold))
                    Text(SecretStorage.usesPrivateFiles ? "密钥保存在这台电脑的本机私有文件中。" : "密钥只保存在这台电脑的系统钥匙串中。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(.borderless)
            }

            if let feedback = model.deepLKeyFeedback, feedback.kind == .error {
                KeySaveFeedbackView(notice: feedback)
            }
            SecureField("粘贴 DeepL API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))

            if let usage = model.deepLUsage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("本月用量")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(usage.characterCount) / \(usage.characterLimit) 字符")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                    ProgressView(value: Double(usage.characterCount), total: Double(max(usage.characterLimit, 1)))
                        .tint(usage.characterCount > usage.characterLimit * 9 / 10 ? Color.red : purple)
                    if usage.characterCount > usage.characterLimit * 9 / 10 {
                        Text("免费额度即将用完（已用 \(usage.usedPercentText)%），请留意")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                    } else {
                        Text("已使用 \(usage.usedPercentText)%，免费额度每月 50 万字符")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(12)
                .glassSurface(cornerRadius: 10)
            } else if model.hasDeepLKey {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在获取用量…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
            }

            Divider()
            Text("打开设置 → DeepL 密钥与帮助，可查看详细申请教程。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                if model.hasDeepLKey {
                    Button("移除密钥") {
                        if model.saveDeepLKey("") {
                            model.setEngine(.apple)
                            isPresented = false
                        }
                    }
                    .foregroundStyle(Color.red.opacity(0.8))
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("保存并使用 DeepL") {
                    if model.saveDeepLKey(apiKey) {
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(purple)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background {
            AdaptiveGlassBackdrop(materialOpacity: 0.92, tintOpacity: 0.24)
                .ignoresSafeArea()
        }
        .onAppear {
            if model.hasDeepLKey {
                Task { await model.fetchDeepLUsage() }
            }
        }
    }
}
