import Foundation

/// A keyboard shortcut like "ctrl+z", "e", "ctrl+shift+z" or "[" in Weylus' key code names
/// (the browser KeyboardEvent.code values that Weylus maps to uinput keys).
struct Shortcut {
    struct Key {
        let code: String
        let key: String
    }

    let modifiers: [Key]
    let key: Key

    private static let named: [String: Key] = [
        "esc": Key(code: "Escape", key: "Escape"),
        "escape": Key(code: "Escape", key: "Escape"),
        "tab": Key(code: "Tab", key: "Tab"),
        "space": Key(code: "Space", key: " "),
        "enter": Key(code: "Enter", key: "Enter"),
        "backspace": Key(code: "Backspace", key: "Backspace"),
        "delete": Key(code: "Delete", key: "Delete"),
        "del": Key(code: "Delete", key: "Delete"),
        "[": Key(code: "BracketLeft", key: "["),
        "]": Key(code: "BracketRight", key: "]"),
        "-": Key(code: "Minus", key: "-"),
        "=": Key(code: "Equal", key: "="),
        ",": Key(code: "Comma", key: ","),
        ".": Key(code: "Period", key: "."),
        "/": Key(code: "Slash", key: "/"),
        ";": Key(code: "Semicolon", key: ";"),
        "up": Key(code: "ArrowUp", key: "ArrowUp"),
        "down": Key(code: "ArrowDown", key: "ArrowDown"),
        "left": Key(code: "ArrowLeft", key: "ArrowLeft"),
        "right": Key(code: "ArrowRight", key: "ArrowRight"),
    ]

    private static let modifierKeys: [String: Key] = [
        "ctrl": Key(code: "ControlLeft", key: "Control"),
        "control": Key(code: "ControlLeft", key: "Control"),
        "shift": Key(code: "ShiftLeft", key: "Shift"),
        "alt": Key(code: "AltLeft", key: "Alt"),
        "super": Key(code: "MetaLeft", key: "Meta"),
        "meta": Key(code: "MetaLeft", key: "Meta"),
        "cmd": Key(code: "MetaLeft", key: "Meta"),
    ]

    static func parse(_ text: String) -> Shortcut? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        // "+" separates keys, so "+" itself can't be bound; use "=" (same key on US layouts).
        let parts = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var mods: [Key] = []
        for m in parts.dropLast() {
            guard let k = modifierKeys[m] else { return nil }
            mods.append(k)
        }
        let key: Key
        if let k = named[last] {
            key = k
        } else if last.count == 1, let c = last.first, c.isLetter, c.isASCII {
            key = Key(code: "Key" + last.uppercased(), key: last)
        } else if last.count == 1, let c = last.first, c.isNumber, c.isASCII {
            key = Key(code: "Digit" + last, key: last)
        } else if let k = modifierKeys[last] {
            key = k // a lone modifier, e.g. "shift" held while squeezing
        } else {
            return nil
        }
        return Shortcut(modifiers: mods, key: key)
    }
}
