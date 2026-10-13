import SwiftUI
import AppKit

struct ImageOCRReviewSheet: View {
    @ObservedObject var model: TranslatorViewModel
    let source: NSImage
    let originalBlocks: [RecognizedImageBlock]
    @State private var blocks: [RecognizedImageBlock]
    @State private var selectedID: UUID?
    @FocusState private var focusedID: UUID?
    @State private var undoBlocks: [(blocks: [RecognizedImageBlock], deleted: [RecognizedImageBlock])] = []
    @State private var deletedBlocks: [RecognizedImageBlock] = []
    @State private var adding = false
    @State private var multiSelect = false
    @State private var selection = Set<UUID>()
    @State private var draftRect: CGRect?
    @State private var splitOffset = 1.0
    @State private var splitAxis: OCRDocument.SplitAxis = .rows
    private var characterCount: Int { blocks.map(\.text).joined(separator: "\n").count }


    init(model: TranslatorViewModel, source: NSImage, blocks: [RecognizedImageBlock]) {
        self.model = model
        self.source = source
        self.originalBlocks = blocks
        _blocks = State(initialValue: blocks)
        _selectedID = State(initialValue: blocks.first?.id)
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return blocks.firstIndex { $0.id == selectedID }
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { blocks.first(where: { $0.id == id })?.text ?? "" },
            set: { value in
                guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
                guard blocks[index].text != value else { return }
                saveUndo()
                blocks[index].text = value
                blocks[index].reviewed = true
            }
        )
    }

    private func saveUndo() {
        undoBlocks.append((blocks, deletedBlocks))
        if undoBlocks.count > 50 { undoBlocks.removeFirst() }
    }

    private func deleteSelectedBlock() {
        guard let index = selectedIndex else { return }
        saveUndo()
        deletedBlocks.append(blocks[index])
        focusedID = nil
        selection.remove(blocks[index].id)
        blocks.remove(at: index)
        selectedID = blocks.isEmpty ? nil : blocks[min(index, blocks.count - 1)].id
    }

    private func inlineFontSize(for rect: CGRect) -> CGFloat {
        min(20, max(11, rect.height * 0.42))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isInitialImageOCRReview ? "检查图片识别文字" : "编辑原图文字")
                        .font(.system(size: 20, weight: .bold))
                    Text(model.isInitialImageOCRReview
                         ? "点击图片中的蓝色文字区域，逐处检查、修改或删除后再翻译。"
                         : "点击原图中的文字区域，即可在原位置直接删字、改字或删除整个区域。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Button("恢复识别结果") {
                    guard confirmYikeAction("恢复全部识别结果？", detail: "当前文字和区域修改将被替换。", action: "确认恢复") else { return }
                    saveUndo()
                    deletedBlocks = []
                    blocks = originalBlocks
                    selection = []
                    selectedID = originalBlocks.first?.id
                    focusedID = nil
                }
                .disabled(blocks == originalBlocks)
                Button(model.isInitialImageOCRReview ? "取消导入" : "取消") {
                    guard blocks == originalBlocks || confirmYikeAction("放弃当前修改？", detail: "尚未应用的文字框修改不会保存。", action: "放弃修改") else { return }
                    model.cancelImageOCREditing()
                }
                .keyboardShortcut(.cancelAction)
                Button("确认并翻译") {
                    model.confirmImageOCRBlocks(blocks)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(characterCount > 5_000 || blocks.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
            .padding(.horizontal, 20)
            .frame(height: 72)

            Divider()

            HStack(spacing: 12) {
                Button("撤销上一步") {
                    guard let previous = undoBlocks.popLast() else { return }
                    blocks = OCRDocument.ordered(previous.blocks)
                    selection = []
                    deletedBlocks = previous.deleted
                    selectedID = blocks.first?.id
                    focusedID = nil
                }.disabled(undoBlocks.isEmpty)
                Toggle("补框", isOn: $adding).toggleStyle(.button)
                    .onChange(of: adding) { _ in focusedID = nil; draftRect = nil }
                Toggle("多选", isOn: $multiSelect).toggleStyle(.button)
                    .onChange(of: multiSelect) { _ in focusedID = nil; selection = [] }
                Button("合并区域") { mergeSelection() }.disabled(selection.count < 2)
                Spacer()
                Text(characterCount > 5_000 ? "超过 5,000 字，请分图或删减区域" : "\(characterCount) / 5,000 字")
                    .foregroundStyle(characterCount > 5_000 ? Color.red : Color.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 8)
            Text(adding ? "在图片上拖动框选，松开后输入文字；框住已删除区域可恢复原文。" : model.ocrSummary)
                .font(.system(size: 12)).foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
            HStack(spacing: 0) {
            GeometryReader { proxy in
                let fit = aspectFitRect(imageSize: source.size, in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .textBackgroundColor)
                    Image(nsImage: source)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)

                    ForEach(deletedBlocks.filter { removed in !blocks.contains(where: { $0.id == removed.id }) }) { block in
                        let box = block.boundingBox
                        Button {
                            saveUndo()
                            blocks = OCRDocument.ordered(blocks + [block])
                            deletedBlocks.removeAll { $0.id == block.id }
                            selectedID = block.id
                        } label: {
                            Rectangle().fill(Color.gray.opacity(0.12))
                                .overlay(Rectangle().stroke(Color.gray, style: StrokeStyle(lineWidth: 1, dash: [4])))
                                .overlay(Image(systemName: "arrow.uturn.backward").foregroundStyle(Color.blue))
                        }
                        .buttonStyle(.plain)
                        .frame(width: box.width * fit.width, height: box.height * fit.height)
                        .position(x: fit.minX + box.midX * fit.width, y: fit.minY + (1 - box.midY) * fit.height)
                        .help("恢复此处删除的文字框")
                    }
                    ForEach(blocks) { block in
                        let box = block.boundingBox
                        let rect = CGRect(
                            x: fit.minX + box.minX * fit.width,
                            y: fit.minY + (1 - box.maxY) * fit.height,
                            width: max(64, box.width * fit.width),
                            height: max(34, box.height * fit.height)
                        )

                        Group {
                            if selectedID == block.id && !multiSelect {
                                ZStack(alignment: .topTrailing) {
                                    TextField("输入文字", text: textBinding(for: block.id), axis: .vertical)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: inlineFontSize(for: rect), weight: .medium))
                                        .lineLimit(1...4)
                                        .padding(.leading, 7)
                                        .padding(.trailing, 28)
                                        .padding(.vertical, 5)
                                        .background(.regularMaterial)
                                        .focused($focusedID, equals: block.id)
                                        .onTapGesture {
                                            selectedID = block.id
                                            focusedID = block.id
                                        }
                                    Button(role: .destructive, action: deleteSelectedBlock) {
                                        Image(systemName: "trash.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 22, height: 22)
                                            .background(Color.red)
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(4)
                                    .help("删除整个文字区域")
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.blue, lineWidth: 2.5)
                                )
                            } else {
                                Button {
                                    if multiSelect {
                                        if selection.contains(block.id) { selection.remove(block.id) }
                                        else { selection.insert(block.id) }
                                    } else {
                                        selectedID = block.id
                                        focusedID = block.id
                                    }
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill((selection.contains(block.id) ? Color.blue : Color.cyan).opacity(selection.contains(block.id) ? 0.22 : 0.035))
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(
                                                (block.needsReview ? Color.orange : Color.cyan).opacity(0.95),
                                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                                            )
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("点击后直接在图片原位置编辑")
                            }
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    }

                    if adding {
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    draftRect = CGRect(x: min(value.startLocation.x, value.location.x),
                                                       y: min(value.startLocation.y, value.location.y),
                                                       width: abs(value.location.x - value.startLocation.x),
                                                       height: abs(value.location.y - value.startLocation.y)).intersection(fit)
                                }
                                .onEnded { value in
                                    defer { draftRect = nil }
                                    guard let box = OCRDocument.normalizedRect(from: value.startLocation, to: value.location, imageRect: fit) else { return }
                                    saveUndo()
                                    let recovered = deletedBlocks.first { candidate in
                                        let overlap = candidate.boundingBox.intersection(box)
                                        return !overlap.isNull && overlap.width * overlap.height > candidate.boundingBox.width * candidate.boundingBox.height * 0.5
                                    }
                                    let block = recovered ?? RecognizedImageBlock(text: "", boundingBox: box, reviewed: true)
                                    deletedBlocks.removeAll { $0.id == block.id }
                                    blocks = OCRDocument.ordered(blocks + [block])
                                    selectedID = block.id
                                    focusedID = block.id
                                    adding = false
                                })
                    }
                    if let draftRect, !draftRect.isNull {
                        Rectangle().stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .frame(width: draftRect.width, height: draftRect.height)
                            .position(x: draftRect.midX, y: draftRect.midY).allowsHitTesting(false)
                    }
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "cursorarrow.click.2")
                            Text("点击图片中的文字即可原地修改；红色按钮删除整个文字区域")
                            Spacer()
                            Text("共 \(blocks.count) 处")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(.regularMaterial)
                    }
                }
            }
            Divider()
            inspector.frame(width: 240)
            }
        }
        .onChange(of: selectedID) { _ in
            splitOffset = Double(max(1, (selectedIndex.map { blocks[$0].text.count } ?? 2) / 2))
        }
        .frame(minWidth: 980, idealWidth: 1080, minHeight: 620, idealHeight: 720)
    }

    private func mergeSelection() {
        guard let merged = OCRDocument.merge(blocks.filter { selection.contains($0.id) }) else { return }
        saveUndo()
        blocks.removeAll { selection.contains($0.id) }
        blocks.append(merged)
        blocks = OCRDocument.ordered(blocks)
        selectedID = merged.id
        selection = []
        multiSelect = false
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("识别检查").font(.headline)
                if multiSelect {
                    Text("已选 \(selection.count) 个区域，点击图片中的区域增减选择。")
                } else if let index = selectedIndex {
                    let block = blocks[index]
                    Label(block.needsReview ? "建议检查" : "已识别 / 已确认",
                          systemImage: block.needsReview ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(block.needsReview ? Color.orange : Color.secondary)
                    if let confidence = block.confidence {
                        Text("识别置信度：\(Int(confidence * 100))%")
                            .font(.caption).foregroundStyle(Color.secondary)
                    }
                    if let candidates = block.candidates, candidates.count > 1 {
                        Menu("切换候选文字") {
                            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                                Button(candidate) { saveUndo(); blocks[index].text = candidate; blocks[index].reviewed = true }
                            }
                        }
                    }
                    TextField("区域文字", text: textBinding(for: block.id), axis: .vertical)
                        .lineLimit(3...10).textFieldStyle(.roundedBorder)
                    Button("确认文字正确") { saveUndo(); blocks[index].reviewed = true }
                    Divider()
                    Text("拆分区域").font(.headline)
                    if block.text.count >= 2 {
                        Picker("方向", selection: $splitAxis) {
                            ForEach(OCRDocument.SplitAxis.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Slider(value: $splitOffset, in: 1...Double(max(2, block.text.count - 1)), step: 1)
                        let offset = min(block.text.count - 1, max(1, Int(splitOffset)))
                        Text(String(block.text.prefix(offset)) + " │ " + String(block.text.dropFirst(offset)))
                            .font(.caption).lineLimit(5)
                        Button("在标记处分开") {
                            let parts = OCRDocument.split(block, at: offset, axis: splitAxis)
                            guard parts.count == 2 else { return }
                            saveUndo()
                            blocks.replaceSubrange(index...index, with: parts)
                            selectedID = parts.first?.id
                        }
                    } else {
                        Text("至少输入两个字后可以拆分。").font(.caption)
                    }
                    Text("框按文字比例拆分；上下用于多行，左右用于同一行。")
                        .font(.caption).foregroundStyle(Color.secondary)
                } else {
                    Text("选择区域查看候选文字，或使用补框添加漏字。")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
