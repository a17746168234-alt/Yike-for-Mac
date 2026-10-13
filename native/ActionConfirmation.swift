import AppKit

@MainActor
func confirmYikeAction(_ title: String, detail: String, action: String = "确认") -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: "取消")
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\u{1b}"
    return alert.runModal() == .alertFirstButtonReturn
}
