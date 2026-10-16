import Foundation

enum LayoutDirection { case toRussian, toEnglish }

struct Conversion {
    let text: String
    let direction: LayoutDirection
}

struct LayoutConverter {
    var englishToRussian: [Character: Character]
    var russianToEnglish: [Character: Character]

    // Used as a fallback when the installed input source has no Unicode layout data.
    static let standard: LayoutConverter = {
        let english = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
        let russian = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")
        var forward: [Character: Character] = [:]
        var backward: [Character: Character] = [:]
        for (a, b) in zip(english, russian) { forward[a] = b; backward[b] = a }
        return LayoutConverter(englishToRussian: forward, russianToEnglish: backward)
    }()

    func convert(_ text: String) -> Conversion? {
        var latin = 0
        var cyrillic = 0
        for scalar in text.unicodeScalars {
            if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) { latin += 1 }
            if (0x410...0x44F).contains(scalar.value) || scalar.value == 0x401 || scalar.value == 0x451 { cyrillic += 1 }
        }
        guard latin + cyrillic > 0 else { return nil }
        let direction: LayoutDirection = cyrillic > latin ? .toEnglish : .toRussian
        let map = direction == .toRussian ? englishToRussian : russianToEnglish
        let result = String(text.map { map[$0] ?? $0 })
        guard result != text else { return nil }
        return Conversion(text: result, direction: direction)
    }
}

struct ControlTap {
    private var started: TimeInterval?
    private var eligible = false

    mutating func leftChanged(isDown: Bool, otherModifiers: Bool, time: TimeInterval) -> Bool {
        if isDown {
            if started == nil { started = time; eligible = !otherModifiers }
            return false
        }
        defer { started = nil; eligible = false }
        guard let start = started else { return false }
        return eligible && !otherModifiers && time - start >= 0.015 && time - start <= 0.65
    }

    mutating func cancel() { eligible = false }
    mutating func reset() { started = nil; eligible = false }
}

struct ShortcutSpec: Codable, Equatable {
    let keyCode: Int?
    let modifiers: [Int]
    let tapCount: Int

    static let defaultShortcut = ShortcutSpec(keyCode: nil, modifiers: [59], tapCount: 1)
    static let modifierMasks: [Int: UInt64] = [59: 0x1, 62: 0x2000, 56: 0x2, 60: 0x4,
                                              55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 63: 0x800000]
    static func pressedModifiers(_ flags: UInt64) -> Set<Int> {
        return Set(modifierMasks.compactMap { flags & $0.value != 0 ? $0.key : nil })
    }
    var isValid: Bool {
        return Set(modifiers).count == modifiers.count && modifiers.allSatisfy { Self.modifierMasks[$0] != nil }
            && (keyCode.map { (0...127).contains($0) && Self.modifierMasks[$0] == nil && $0 != 57 } ?? !modifiers.isEmpty)
            && (tapCount == 1 || (tapCount == 2 && keyCode == nil && modifiers.count == 1))
    }
    static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",
            12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",
            24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",
            36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",
            48:"Tab",49:"Пробел",50:"`",51:"Delete",53:"Escape",54:"правый Command",55:"левый Command",
            56:"левый Shift",58:"левый Option",59:"левый Control",60:"правый Shift",61:"правый Option",
            62:"правый Control",63:"Fn",64:"F17",65:"Num .",67:"Num *",69:"Num +",71:"Clear",75:"Num /",
            76:"Enter",78:"Num −",79:"F18",80:"F19",81:"Num =",82:"Num 0",83:"Num 1",84:"Num 2",
            85:"Num 3",86:"Num 4",87:"Num 5",88:"Num 6",89:"Num 7",90:"F20",91:"Num 8",92:"Num 9",
            96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",
            109:"F10",111:"F12",113:"F15",114:"Help",115:"Home",116:"Page Up",117:"Forward Delete",
            118:"F4",119:"End",120:"F2",121:"Page Down",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return names[code] ?? "Клавиша \(code)"
    }
    var displayName: String {
        let parts = modifiers.sorted().map { Self.keyName($0) } + (keyCode.map { [Self.keyName($0)] } ?? [])
        return (tapCount == 2 ? "Двойное нажатие: " : "") + parts.joined(separator: " + ")
    }
}

struct ShortcutMatch { let trigger: Bool; let suppress: Bool }

struct ShortcutMatcher {
    var shortcut: ShortcutSpec
    private var down: Set<Int> = []
    private var gesture: Set<Int> = []
    private var started: TimeInterval?
    private var eligible = false
    private var lastTap: TimeInterval?
    private var swallowedKeys: Set<Int> = []

    init(_ shortcut: ShortcutSpec) { self.shortcut = shortcut }
    mutating func reset() {
        down = []; gesture = []; started = nil; eligible = false; lastTap = nil; swallowedKeys = []
    }
    mutating func cancelGesture() { eligible = false; lastTap = nil }
    mutating func flagsChanged(_ flags: UInt64, time: TimeInterval) -> Bool {
        let now = ShortcutSpec.pressedModifiers(flags)
        if down.isEmpty && !now.isEmpty {
            gesture = []; started = time; eligible = true
        }
        gesture.formUnion(now)
        let released = !down.isEmpty && now.isEmpty
        down = now
        guard released, shortcut.keyCode == nil else { return false }
        defer { gesture = []; started = nil; eligible = false }
        guard eligible, let start = started, time - start >= 0.015, time - start <= 0.65,
              gesture == Set(shortcut.modifiers) else { lastTap = nil; return false }
        if shortcut.tapCount == 2 {
            if let previous = lastTap, time - previous <= 0.4 { lastTap = nil; return true }
            lastTap = time; return false
        }
        lastTap = nil; return true
    }
    mutating func keyDown(_ code: Int, flags: UInt64, isRepeat: Bool) -> ShortcutMatch {
        cancelGesture()
        if swallowedKeys.contains(code) { return ShortcutMatch(trigger: false, suppress: true) }
        guard shortcut.keyCode == code, ShortcutSpec.pressedModifiers(flags) == Set(shortcut.modifiers) else {
            return ShortcutMatch(trigger: false, suppress: false)
        }
        swallowedKeys.insert(code)
        return ShortcutMatch(trigger: !isRepeat, suppress: true)
    }
    mutating func keyUp(_ code: Int) -> Bool { return swallowedKeys.remove(code) != nil }
}

struct ExcludedApplication: Codable, Equatable {
    let identifier: String
    let name: String
    let path: String
    static func identity(bundleIdentifier: String?, path: String) -> String {
        if let identifier = bundleIdentifier, !identifier.isEmpty { return "bundle:" + identifier }
        return "path:" + URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

struct WordContext {
    private(set) var text = ""
    mutating func append(_ value: String) {
        text += value
        if text.utf16.count > 4096 { clear() }
    }
    mutating func backspace() { if !text.isEmpty { text.removeLast() } }
    mutating func clear() { text = "" }

    static func lastWordRange(in value: String, caretUTF16: Int) -> NSRange? {
        let ns = value as NSString
        guard caretUTF16 > 0 && caretUTF16 <= ns.length else { return nil }
        let prefix = ns.substring(to: caretUTF16)
        let expression = try! NSRegularExpression(pattern: "[^\\s]+[ \\t]*\\z")
        let range = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length))?.range
        return range
    }

    var lastWord: String? {
        guard let range = Self.lastWordRange(in: text, caretUTF16: text.utf16.count) else { return nil }
        return (text as NSString).substring(with: range)
    }
}
