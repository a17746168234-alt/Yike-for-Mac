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

struct ImagePreviewItem: Identifiable {
    let id = UUID()
    let title: String
    let image: NSImage
}

struct TranslationImagePane: View {
    let image: NSImage
    let title: String
    let accent: Color
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    HStack {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.62))
                            .clipShape(Capsule())
                        Spacer()
                        Label("点击放大", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(accent.opacity(0.90))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("点击放大查看\(title)")
    }
}

struct ScrollWheelZoomCapture: NSViewRepresentable {
    @Binding var zoom: Double

    func makeNSView(context: Context) -> ScrollWheelZoomCaptureView {
        let view = ScrollWheelZoomCaptureView()
        view.onScroll = adjustZoom
        return view
    }

    func updateNSView(_ nsView: ScrollWheelZoomCaptureView, context: Context) {
        nsView.onScroll = adjustZoom
    }

    private func adjustZoom(
        deltaY: CGFloat,
        isDirectionInvertedFromDevice: Bool
    ) {
        let deviceDeltaY = isDirectionInvertedFromDevice ? -Double(deltaY) : Double(deltaY)
        zoom = ImageZoomPolicy.adjustedZoom(
            current: zoom,
            deviceDeltaY: deviceDeltaY
        )
    }
}

final class ScrollWheelZoomCaptureView: NSView {
    var onScroll: ((CGFloat, Bool) -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                return event
            }

            // A trackpad reports precise deltas. Let the ScrollView keep these events so
            // two-finger gestures pan the enlarged image horizontally and vertically.
            guard ImageZoomPolicy.shouldZoom(
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
            ) else { return event }

            // Trackpad momentum should not keep changing the zoom after the gesture ends.
            guard event.momentumPhase.isEmpty else { return nil }
            self.onScroll?(
                event.scrollingDeltaY,
                event.isDirectionInvertedFromDevice
            )
            return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        stopMonitoring()
    }

    private func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}

struct ImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: ImagePreviewItem
    @State private var zoom: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 18, weight: .bold))
                    Text("鼠标滚轮缩放 · 触控板双指移动")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(Color.secondary)
                Slider(value: $zoom, in: 1...3, step: 0.1)
                    .frame(width: 180)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(Color.secondary)
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 44, alignment: .trailing)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)

            Divider()

            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: item.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(
                            width: max(proxy.size.width, proxy.size.width * zoom),
                            height: max(proxy.size.height, proxy.size.height * zoom)
                        )
                }
                .background(Color(nsColor: .textBackgroundColor))
                .background(ScrollWheelZoomCapture(zoom: $zoom))
            }
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 560, idealHeight: 720)
    }
}

func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
          containerSize.width > 0, containerSize.height > 0 else { return .zero }
    let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
        x: (containerSize.width - size.width) / 2,
        y: (containerSize.height - size.height) / 2,
        width: size.width,
        height: size.height
    )
}

struct ImageTranslationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: NSImage
    let resetBlocks: [EditableImageTranslationBlock]
    let initialBlocks: [EditableImageTranslationBlock]
    @State private var undoBlocks = EditorUndoHistory<[EditableImageTranslationBlock]>()
    let onApply: ([EditableImageTranslationBlock]) -> Void
    @State private var blocks: [EditableImageTranslationBlock]
    @State private var selectedID: UUID?
    @State private var dragStartBox: CGRect?

    init(
        source: NSImage,
        blocks: [EditableImageTranslationBlock],
        resetBlocks: [EditableImageTranslationBlock],
        onApply: @escaping ([EditableImageTranslationBlock]) -> Void
    ) {
        self.source = source
        self.resetBlocks = resetBlocks
        self.initialBlocks = blocks
        self.onApply = onApply
        _blocks = State(initialValue: blocks)
        _selectedID = State(initialValue: blocks.first?.id)
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return blocks.firstIndex { $0.id == selectedID }
    }

    private func binding<Value>(for keyPath: WritableKeyPath<EditableImageTranslationBlock, Value>) -> Binding<Value> {
        Binding(
            get: {
                guard let index = selectedIndex else {
                    preconditionFailure("没有选中译文框")
                }
                return blocks[index][keyPath: keyPath]
            },
            set: { value in
                guard let index = selectedIndex else { return }
                undoBlocks.append(blocks)
                blocks[index][keyPath: keyPath] = value
            }
        )
    }

    private func sizeBinding(isWidth: Bool) -> Binding<Double> {
        Binding(
            get: {
                guard let index = selectedIndex else { return 0.1 }
                let box = blocks[index].boundingBox
                return Double(isWidth ? box.width : box.height)
            },
            set: { value in
                guard let index = selectedIndex else { return }
                var box = blocks[index].boundingBox
                if isWidth {
                    box.size.width = CGFloat(value)
                    box.origin.x = min(box.origin.x, 1 - box.width)
                } else {
                    box.size.height = CGFloat(value)
                    box.origin.y = min(box.origin.y, 1 - box.height)
                }
                undoBlocks.append(blocks)
                blocks[index].boundingBox = box
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("编辑图片译文")
                        .font(.system(size: 18, weight: .bold))
                    Text("拖动蓝色译文框改变位置，右侧可修改文字、大小、颜色和对齐。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Button("撤销上一步") {
                    guard let previous = undoBlocks.popLast() else { return }
                    blocks = previous
                    selectedID = blocks.first?.id
                }.disabled(undoBlocks.isEmpty)
                Button("重置") {
                    guard confirmYikeAction("重置图片译文？", detail: "文字、位置和样式将恢复为初始翻译结果。", action: "确认重置") else { return }
                    let restored = resetBlocks
                    blocks = restored
                    undoBlocks.reset()
                    dragStartBox = nil
                    selectedID = restored.first?.id
                }
                Button("取消") {
                    guard blocks == initialBlocks || confirmYikeAction("放弃图片修改？", detail: "当前未应用的修改不会保存。", action: "放弃修改") else { return }
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    onApply(blocks)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            Divider()

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
                        ForEach(blocks) { block in
                            let box = block.boundingBox
                            let rect = CGRect(
                                x: fit.minX + box.minX * fit.width,
                                y: fit.minY + (1 - box.maxY) * fit.height,
                                width: max(18, box.width * fit.width),
                                height: max(16, box.height * fit.height)
                            )
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.blue.opacity(selectedID == block.id ? 0.23 : 0.10))
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(selectedID == block.id ? Color.blue : Color.white.opacity(0.8), lineWidth: selectedID == block.id ? 2 : 1)
                                Text(block.translatedText)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(2)
                                    .padding(3)
                            }
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if selectedID != block.id {
                                            selectedID = block.id
                                            undoBlocks.append(blocks)
                                            dragStartBox = block.boundingBox
                                        } else if dragStartBox == nil {
                                            undoBlocks.append(blocks)
                                            dragStartBox = block.boundingBox
                                        }
                                        guard let start = dragStartBox,
                                              let index = blocks.firstIndex(where: { $0.id == block.id }),
                                              fit.width > 0, fit.height > 0 else { return }
                                        let deltaX = value.translation.width / fit.width
                                        let deltaY = -value.translation.height / fit.height
                                        var moved = start
                                        moved.origin.x = min(max(0, start.minX + deltaX), 1 - start.width)
                                        moved.origin.y = min(max(0, start.minY + deltaY), 1 - start.height)
                                        blocks[index].boundingBox = moved
                                    }
                                    .onEnded { _ in dragStartBox = nil }
                            )
                        }
                    }
                    .clipped()
                }

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    if selectedIndex != nil {
                        Text("选中的译文框")
                            .font(.system(size: 14, weight: .bold))
                        TextEditor(text: binding(for: \.translatedText))
                            .font(.system(size: 13))
                            .frame(minHeight: 100)
                            .padding(7)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Group {
                            HStack {
                                Text("字号")
                                Slider(value: binding(for: \.fontScale), in: 0.6...2, step: 0.05)
                                Text("\(Int(binding(for: \.fontScale).wrappedValue * 100))%")
                                    .frame(width: 42, alignment: .trailing)
                            }
                            Picker("对齐", selection: binding(for: \.alignment)) {
                                ForEach(ImageOverlayTextAlignment.allCases) { alignment in
                                    Text(alignment.title).tag(alignment)
                                }
                            }
                            .pickerStyle(.segmented)
                            Picker("文字颜色", selection: binding(for: \.textColor)) {
                                ForEach(ImageOverlayTextColor.allCases) { color in
                                    Text(color.title).tag(color)
                                }
                            }
                            HStack {
                                Text("宽度")
                                Slider(value: sizeBinding(isWidth: true), in: 0.04...0.96, step: 0.005)
                            }
                            HStack {
                                Text("高度")
                                Slider(value: sizeBinding(isWidth: false), in: 0.025...0.60, step: 0.005)
                            }
                        }
                        .font(.system(size: 12))

                        Spacer()
                        Button(role: .destructive) {
                            guard let index = selectedIndex else { return }
                            undoBlocks.append(blocks)
                            blocks.remove(at: index)
                            selectedID = blocks.first?.id
                        } label: {
                            Label("删除这个译文框", systemImage: "trash")
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.dashed")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.secondary)
                            Text("没有译文框")
                                .font(.system(size: 14, weight: .semibold))
                            Text("可点击“撤销上一步”恢复删除，或“重置”恢复识别结果。")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(18)
                .frame(width: 310)
            }
        }
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 620, idealHeight: 760)
    }
}

struct ImageComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: NSImage
    let translated: NSImage
    @State private var reveal: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("原图与译图对比")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Text("拖动滑杆查看")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                Slider(value: $reveal, in: 0...1)
                    .frame(width: 180)
                Button("完成") { dismiss() }
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            Divider()
            GeometryReader { proxy in
                let fit = aspectFitRect(imageSize: source.size, in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .textBackgroundColor)
                    Image(nsImage: source)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                    Image(nsImage: translated)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: fit.width * reveal)
                        }
                        .position(x: fit.midX, y: fit.midY)
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 2)
                        .frame(height: fit.height)
                        .position(x: fit.minX + fit.width * reveal, y: fit.midY)
                    Text("译图")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.58)).foregroundStyle(.white)
                        .clipShape(Capsule())
                        .position(x: fit.minX + 34, y: fit.minY + 22)
                    Text("原图")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.blue.opacity(0.78)).foregroundStyle(.white)
                        .clipShape(Capsule())
                        .position(x: fit.maxX - 34, y: fit.minY + 22)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard fit.width > 0 else { return }
                    reveal = min(1, max(0, (value.location.x - fit.minX) / fit.width))
                })
            }
        }
        .frame(minWidth: 780, idealWidth: 980, minHeight: 560, idealHeight: 720)
    }
}
