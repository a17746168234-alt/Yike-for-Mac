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

/// Keep the explicitly styled disabled label legible instead of dimming it twice.
struct TranslationActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.88 : 1)
    }
}

/// Shared empty-state typography and baseline for both editor panes.
struct EditorEmptyState: View {
    let title: String
    var symbol: String? = nil
    var imageHint: String? = nil

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(MacVisualTokens.tertiaryLabel)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 15, weight: .regular))
            }
            if let imageHint {
                Label(imageHint, systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 12, weight: .regular))
            }
        }
        .foregroundStyle(MacVisualTokens.secondaryLabel)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.top, 86)
        .allowsHitTesting(false)
    }
}

/// Native editable result, with selection, deletion, multiline input and undo.
struct ResultTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isVoiceActive = false
    var onVoiceReturn: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = NSTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 24, height: 20)
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        editor.defaultParagraphStyle = paragraph
        editor.string = text
        editor.setAccessibilityLabel("译文，可编辑")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.textColor = .labelColor
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ResultTextEditor
        init(parent: ResultTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  parent.isVoiceActive,
                  NSApp.currentEvent?.modifierFlags.contains(.shift) != true else { return false }
            if NSApp.currentEvent?.isARepeat != true { parent.onVoiceReturn() }
            return true
        }
    }
}

struct SubmitTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isDarkMode: Bool
    let onSubmit: () -> Void
    let onImageDrop: (URL) -> Void

    private var editorTextColor: NSColor { .labelColor }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = ImageDropTextView()
        textView.onImageDrop = onImageDrop
        textView.registerForDraggedTypes([.fileURL])
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        textView.textColor = editorTextColor
        textView.insertionPointColor = .controlAccentColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        textView.defaultParagraphStyle = paragraph
        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ImageDropTextView else { return }
        textView.onImageDrop = onImageDrop
        textView.textColor = editorTextColor
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmitTextEditor

        init(parent: SubmitTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let limited = String(textView.string.prefix(maxSourceCharacters))
            if textView.string != limited {
                textView.string = limited
            }
            parent.text = limited
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                if NSApp.currentEvent?.isARepeat != true { parent.onSubmit() }
                return true
            }
            return false
        }
    }
}

final class ImageDropTextView: NSTextView {
    var onImageDrop: ((URL) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURL(from: sender.draggingPasteboard) == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURL(from: sender.draggingPasteboard) == nil ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = imageURL(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        onImageDrop?(url)
        return true
    }

    private func imageURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let fileURL = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL])?.first as URL? else {
            return nil
        }
        guard let type = UTType(filenameExtension: fileURL.pathExtension), type.conforms(to: .image) else {
            return nil
        }
        return fileURL
    }
}

struct LanguageMenu: View {
    let color: Color
    let textColor: Color
    let selection: String
    var options: [String] = concreteLanguages
    let onChange: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { code in
                Button(languageName(code)) { onChange(code) }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
                Text(languageName(selection))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(textColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(MacVisualTokens.tertiaryLabel)
            }
            .macHoverControl(horizontalPadding: 10, height: 34)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
