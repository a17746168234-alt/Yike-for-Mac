import Foundation
import Carbon.HIToolbox

struct SelectionShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let storageKey = "yike.selection.shortcut"
    static let defaultValue = SelectionShortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey))
    static let keys: [(String, UInt32)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3),
        ("G", 5), ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37),
        ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15),
        ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7),
        ("Y", 16), ("Z", 6), ("F1", 122), ("F2", 120), ("F3", 99),
        ("F4", 118), ("F5", 96), ("F6", 97), ("F7", 98), ("F8", 100),
        ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111)
    ]

    var label: String {
        let prefix = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined()
        return prefix + (Self.keys.first { $0.1 == keyCode }?.0 ?? "?")
    }

    var validationError: String? {
        let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        guard Self.keys.contains(where: { $0.1 == keyCode }), modifiers & ~allowed == 0 else {
            return "请选择支持的按键组合"
        }
        guard modifiers & UInt32(cmdKey | controlKey) != 0 else {
            return "请至少选择 Command 或 Control，避免影响正常输入"
        }
        let editingKeys: Set<UInt32> = [0, 8, 9, 7, 6, 1, 13, 12, 4, 46, 45, 31, 35, 17]
        if modifiers == UInt32(cmdKey) && editingKeys.contains(keyCode) {
            return "这个组合是常用系统快捷键，请再加一个修饰键"
        }
        if keyCode == 12 && modifiers & UInt32(cmdKey | shiftKey) == UInt32(cmdKey | shiftKey) {
            return "请避开系统注销快捷键"
        }
        return nil
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.validationError == nil else { return defaultValue }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard validationError == nil, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
