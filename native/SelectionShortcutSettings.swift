import SwiftUI
import Carbon.HIToolbox

struct SelectionShortcutSettings: View {
    @ObservedObject var model: TranslatorViewModel
    @State private var draft = SelectionShortcut.load()
    @State private var current = SelectionShortcut.load()
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("选中文字后唤起", systemImage: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(current.label).font(.system(size: 16, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
            Text("在其他应用中选中文字，按此快捷键打开翻译悬浮窗。无需先打开 Yike 主窗口。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                modifier("⌃ Control", flag: controlKey)
                modifier("⌥ Option", flag: optionKey)
                modifier("⇧ Shift", flag: shiftKey)
                modifier("⌘ Command", flag: cmdKey)
            }
            HStack {
                Text("主按键")
                Picker("主按键", selection: $draft.keyCode) {
                    ForEach(SelectionShortcut.keys, id: \.1) { key in
                        Text(key.0).tag(key.1)
                    }
                }
                .labelsHidden().frame(width: 90)
                Spacer()
                Button("恢复默认") { apply(.defaultValue) }
                Button("保存快捷键") { apply(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == current || draft.validationError != nil)
            }
            if let error = draft.validationError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            }
            if let message {
                Label(message, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(failed ? Color.orange : Color.secondary)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("辅助功能授权").font(.system(size: 13, weight: .medium))
                    Text(model.accessibilityPermissionText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开系统设置") { NoticeAction.openAccessibilitySettings.open() }
            }
            Text("首次使用请在系统设置 → 隐私与安全性 → 辅助功能中允许 Yike。快捷键只负责呼出悬浮窗，读取其他应用的选中文字仍需要授权。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(16).glassSurface(cornerRadius: 14)
    }

    private func modifier(_ title: String, flag: Int) -> some View {
        Toggle(title, isOn: Binding(
            get: { draft.modifiers & UInt32(flag) != 0 },
            set: { if $0 { draft.modifiers |= UInt32(flag) } else { draft.modifiers &= ~UInt32(flag) } }
        ))
        .toggleStyle(.button)
        .font(.system(size: 11))
    }

    private func apply(_ value: SelectionShortcut) {
        guard value.validationError == nil else { return }
        guard let controller = GlobalHotKeyController.active else {
            failed = true; message = "快捷键服务尚未就绪，请重新打开 Yike"; return
        }
        let status = controller.apply(value)
        guard status == noErr else {
            failed = true; message = "该组合无法注册，可能已被占用。原快捷键仍然有效，请换一个组合。"; return
        }
        current = value
        draft = value
        failed = false
        message = "已保存，立即生效"
    }
}
