import Cocoa
import Carbon
import ApplicationServices

private let injectedTag: Int64 = 0x43464C4950

private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &result) == .success ? result : nil
}

private struct InputLayouts {
    let english: TISInputSource?
    let russian: TISInputSource?
    let converter: LayoutConverter

    init() {
        let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
            guard let value = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
        }
        func matching(_ language: String) -> TISInputSource? {
            let candidates = list.filter {
                let languages = property($0, kTISPropertyInputSourceLanguages) as? [String] ?? []
                return languages.contains(language) && (property($0, kTISPropertyInputSourceIsSelectCapable) as? Bool == true)
            }
            let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let currentID = property(current, kTISPropertyInputSourceID) as? String
            return candidates.first { property($0, kTISPropertyInputSourceID) as? String == currentID }
                ?? candidates.first { property($0, kTISPropertyUnicodeKeyLayoutData) != nil }
                ?? candidates.first
        }
        english = matching("en")
        russian = matching("ru")
        var forward = LayoutConverter.standard.englishToRussian
        var backward = LayoutConverter.standard.russianToEnglish
        if let en = english, let ru = russian,
           let enData = property(en, kTISPropertyUnicodeKeyLayoutData) as? Data,
           let ruData = property(ru, kTISPropertyUnicodeKeyLayoutData) as? Data {
            func symbol(_ data: Data, _ key: UInt16, _ modifiers: UInt32) -> Character? {
                return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Character? in
                    guard let base = bytes.baseAddress else { return nil }
                    let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 8)
                    let error = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), modifiers,
                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                        chars.count, &length, &chars)
                    guard error == noErr && length > 0 else { return nil }
                    let string = String(utf16CodeUnits: chars, count: length)
                    guard string.count == 1, let char = string.first,
                        !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
                    return char
                }
            }
            forward = [:]; backward = [:]
            // The main typing keys, including ISO's extra key. Excludes Return, Tab and Space.
            let keys = Array(UInt16(0)...UInt16(50)).filter { ![36, 48, 49].contains($0) }
            for modifiers: UInt32 in [0, UInt32(shiftKey >> 8)] {
                for key in keys {
                    if let a = symbol(enData, key, modifiers), let b = symbol(ruData, key, modifiers) {
                        forward[a] = b; backward[b] = a
                    }
                }
            }
        }
        converter = LayoutConverter(englishToRussian: forward, russianToEnglish: backward)
    }

    func select(_ direction: LayoutDirection) -> Bool {
        guard let source = direction == .toRussian ? russian : english else { return false }
        return TISSelectInputSource(source) == noErr
    }
}

private struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    init(_ board: NSPasteboard) {
        items = (board.pasteboardItems ?? []).map { item in
            var saved: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { saved[type] = data } }
            return saved
        }
    }
    func restore(_ board: NSPasteboard, ifUnchanged count: Int) {
        guard board.changeCount == count else { return }
        board.clearContents()
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}

private final class ConverterEngine {
    private let queue = DispatchQueue(label: "local.controlflip.conversion")
    private let lock = NSLock()
    private var generation = 0
    private var busy = false
    var report: ((String) -> Void)?

    func invalidate() { lock.lock(); generation += 1; lock.unlock() }
    private func valid(_ token: Int, _ pid: pid_t) -> Bool {
        lock.lock(); let same = generation == token; lock.unlock()
        return same && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !IsSecureEventInputEnabled()
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: injectedTag)
            event.post(tap: .cgSessionEventTap)
        }
    }
    private func pause(_ duration: TimeInterval = 0.04) { Thread.sleep(forTimeInterval: duration) }
    private func status(_ text: String) { DispatchQueue.main.async { self.report?(text) } }

    func run(bufferedWord: String?) {
        guard !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication else {
            status("В защищённом поле исправление недоступно"); return
        }
        lock.lock()
        guard !busy else { lock.unlock(); return }
        busy = true
        let token = generation
        lock.unlock()
        let pid = app.processIdentifier
        // Capture input sources on the main thread; never select a source from the event callback.
        let layouts = InputLayouts()
        guard layouts.english != nil && layouts.russian != nil else {
            lock.lock(); busy = false; lock.unlock()
            status("Добавьте английскую и русскую раскладки в настройках macOS"); return
        }
        queue.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            guard self.valid(token, pid) else { return }
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.3)
            var focused: AXUIElement?
            if let object = attribute(axApp, kAXFocusedUIElementAttribute as CFString), CFGetTypeID(object) == AXUIElementGetTypeID() {
                focused = (object as! AXUIElement)
            }
            if let element = focused {
                AXUIElementSetMessagingTimeout(element, 0.3)
                let subrole = attribute(element, kAXSubroleAttribute as CFString) as? String
                guard subrole != "AXSecureTextField" else { self.status("В поле пароля исправление недоступно"); return }
            }
            var selectedRange: CFRange?
            if let element = focused, let value = attribute(element, kAXSelectedTextRangeAttribute as CFString), CFGetTypeID(value) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 { selectedRange = range }
            }
            let selected = focused.flatMap { attribute($0, kAXSelectedTextAttribute as CFString) as? String }
            if let text = selected, !text.isEmpty {
                self.replaceSelection(text, layouts: layouts, token: token, pid: pid)
                return
            }
            // Prefer the real text and caret position over the typed-key fallback.
            if let element = focused, let range = selectedRange, range.length == 0,
               let value = attribute(element, kAXValueAttribute as CFString) as? String,
               let wordRange = WordContext.lastWordRange(in: value, caretUTF16: range.location) {
                let word = (value as NSString).substring(with: wordRange)
                guard let converted = layouts.converter.convert(word), self.valid(token, pid) else { return }
                var target = CFRange(location: wordRange.location, length: wordRange.length)
                guard let axRange = AXValueCreate(.cfRange, &target) else { return }
                if AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success {
                    if self.valid(token, pid) {
                        self.paste(converted, layouts: layouts, token: token, pid: pid)
                    }
                    return
                }
            }
            // Some Electron/browser editors do not expose selection text through Accessibility.
            // Copy detects their selection; all original clipboard formats are restored afterward.
            guard self.valid(token, pid) else { return }
            let board = NSPasteboard.general
            let snapshot = ClipboardSnapshot(board)
            board.clearContents()
            var ownedCount = board.changeCount
            defer { snapshot.restore(board, ifUnchanged: ownedCount) }
            self.key(8, flags: .maskCommand) // Copy
            for _ in 0..<8 {
                self.pause(0.025)
                if board.changeCount != ownedCount { break }
                if !self.valid(token, pid) { return }
            }
            let copyCount = board.changeCount
            guard self.valid(token, pid) else { return }
            let copied = copyCount != ownedCount ? board.string(forType: .string) : nil
            if copyCount != ownedCount { ownedCount = copyCount }
            guard self.valid(token, pid) else { return }
            if let text = copied, !text.isEmpty {
                guard let converted = layouts.converter.convert(text) else { self.status("В выделении нет текста для исправления"); return }
                if let count = self.paste(converted, layouts: layouts, token: token, pid: pid, preserving: snapshot) { ownedCount = count }
            } else if let word = bufferedWord, let converted = layouts.converter.convert(word) {
                // The buffer is reset on cursor movement, mouse clicks, app changes and shortcuts.
                // Select exactly the typed suffix; this keeps replacement in a single paste/undo step.
                for _ in 0..<word.count {
                    guard self.valid(token, pid) else { return }
                    self.key(123, flags: .maskShift)
                }
                self.pause()
                guard self.valid(token, pid) else { return }
                if let count = self.paste(converted, layouts: layouts, token: token, pid: pid, preserving: snapshot) { ownedCount = count }
            } else {
                self.status("Выделите текст или наберите слово перед нажатием Control")
            }
        }
    }

    private func replaceSelection(_ text: String, layouts: InputLayouts, token: Int, pid: pid_t) {
        guard let converted = layouts.converter.convert(text) else { status("В выделении нет текста для исправления"); return }
        paste(converted, layouts: layouts, token: token, pid: pid)
    }

    @discardableResult private func paste(_ converted: Conversion, layouts: InputLayouts, token: Int, pid: pid_t,
                                         preserving snapshot: ClipboardSnapshot? = nil) -> Int? {
        let board = NSPasteboard.general
        guard valid(token, pid) else { return nil }
        let saved = snapshot ?? ClipboardSnapshot(board)
        board.clearContents()
        guard board.setString(converted.text, forType: .string) else {
            saved.restore(board, ifUnchanged: board.changeCount)
            status("Не удалось получить доступ к буферу обмена")
            return nil
        }
        let ownedCount = board.changeCount
        key(9, flags: .maskCommand) // Paste
        DispatchQueue.main.async {
            guard self.valid(token, pid) else { return }
            self.report?(layouts.select(converted.direction) ? "Исправлено · ⌃" : "Текст исправлен; язык ввода переключить не удалось")
        }
        // Allow the receiving application to read the pasteboard before restoring it.
        pause(0.25)
        // With an existing clipboard transaction its caller owns restoration.
        // Return our write count, never somebody else's later clipboard count.
        if snapshot == nil { saved.restore(board, ifUnchanged: ownedCount) }
        return ownedCount
    }
}

private final class InputMonitor {
    let engine = ConverterEngine()
    var onState: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var shortcut = ShortcutSpec.defaultShortcut {
        didSet { matcher = ShortcutMatcher(shortcut); clear(); engine.invalidate() }
    }
    private var matcher = ShortcutMatcher(.defaultShortcut)
    var exclusions: [ExcludedApplication] = [] { didSet { clear(); matcher.reset(); engine.invalidate() } }
    var recording = false { didSet { clear(); matcher.reset(); engine.invalidate() } }
    private var context = WordContext()
    private var appObserver: NSObjectProtocol?
    private(set) var keyboardEvents = 0
    private(set) var shortcutActivations = 0
    var enabled = true {
        didSet { clear(); matcher.reset(); engine.invalidate() }
    }
    var active: Bool { return tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clear(); self?.matcher.reset(); self?.engine.invalidate()
        }
    }
    func clear() { context.clear() }
    func stop() {
        clear(); matcher.reset(); engine.invalidate()
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    func start() {
        // AXIsProcessTrusted can disagree with the effective event permission.
        // Let WindowServer make the actual access decision when creating a tap.
        if active { return }
        if tap != nil { stop() }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info = info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<InputMonitor>.fromOpaque(info).takeUnretainedValue().handle(type, event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap = tap else { onState?(false); return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Creating a tap for mouse + keyboard may succeed with keyboard bits
        // removed. Do not report Ready for a mouse-only tap.
        var count: UInt32 = 0
        if CGGetEventTapList(0, nil, &count) == .success && count > 0 {
            var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
            if CGGetEventTapList(count, &taps, &count) == .success {
                let keyboardMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
                let permitted = taps.prefix(Int(count)).contains { $0.tappingProcess == getpid() && $0.enabled && ($0.eventsOfInterest & keyboardMask) == keyboardMask }
                if !permitted { stop(); onState?(false); return }
            }
        }
        onState?(true)
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            clear(); matcher.reset(); engine.invalidate()
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            DispatchQueue.main.async { self.stop(); self.onState?(false) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != injectedTag else { return Unmanaged.passUnretained(event) }
        if type == .keyDown || type == .flagsChanged { keyboardEvents += 1 }
        guard enabled, !recording else { return Unmanaged.passUnretained(event) }
        if let front = NSWorkspace.shared.frontmostApplication {
            let identity = ExcludedApplication.identity(bundleIdentifier: front.bundleIdentifier, path: front.bundleURL?.path ?? "")
            if exclusions.contains(where: { $0.identifier == identity }) {
                clear(); matcher.reset(); engine.invalidate(); return Unmanaged.passUnretained(event)
            }
        }
        guard !IsSecureEventInputEnabled() else {
            clear(); matcher.reset(); engine.invalidate(); return Unmanaged.passUnretained(event)
        }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged {
            if matcher.flagsChanged(event.flags.rawValue, time: Double(event.timestamp) / 1_000_000_000) { trigger() }
        } else if type == .keyUp {
            if matcher.keyUp(key) { return nil }
        } else if type == .keyDown {
            let match = matcher.keyDown(key, flags: event.flags.rawValue, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            if match.trigger { engine.invalidate(); trigger() }
            if match.suppress { return nil }
            engine.invalidate()
            if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty {
                clear()
            } else if key == 51 { context.backspace() }
            else if [36, 48, 53, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(key) { clear() }
            else {
                var chars = [UniChar](repeating: 0, count: 32)
                var count = 0
                event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &count, unicodeString: &chars)
                if count > 0 {
                    let value = String(utf16CodeUnits: chars, count: count)
                    if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { clear() }
                    else { context.append(value) }
                }
            }
        } else { engine.invalidate(); matcher.cancelGesture(); clear() }
        return Unmanaged.passUnretained(event)
    }
    private func trigger() {
        shortcutActivations += 1
        let word = context.lastWord
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        clear()
        DispatchQueue.main.async {
            guard self.enabled, !self.recording, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.engine.run(bufferedWord: word)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = InputMonitor()
    private var item: NSStatusItem!
    private var statusItem = NSMenuItem(title: "Ожидание доступа…", action: nil, keyEquivalent: "")
    private var enabledItem: NSMenuItem!
    private var timer: Timer?
    private var preferences: PreferencesController?
    private var operationStatus = "Готово · клавиатура подключена"

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "shortcut"), let value = try? JSONDecoder().decode(ShortcutSpec.self, from: data), value.isValid { monitor.shortcut = value }
        if let data = defaults.data(forKey: "excludedApplications"), let value = try? JSONDecoder().decode([ExcludedApplication].self, from: data) { monitor.exclusions = value }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadPreferences()
        LoginItemManager.shared.enableInitiallyIfNeeded()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.image = MenuBarIcon.makeImage()
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("ControlFlip — а/я")
        item.button?.toolTip = "ControlFlip — исправление раскладки"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "ControlFlip · русский ↔ английский", action: nil, keyEquivalent: ""))
        menu.addItem(statusItem)
        statusItem.target = self
        menu.addItem(.separator())
        enabledItem = NSMenuItem(title: "Исправление включено", action: #selector(toggle), keyEquivalent: "")
        enabledItem.target = self; enabledItem.state = .on; menu.addItem(enabledItem)
        let settings = NSMenuItem(title: "Настройки…", action: #selector(showPreferences), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let help = NSMenuItem(title: "Как пользоваться…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self; menu.addItem(help)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить ControlFlip", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        monitor.engine.report = { [weak self] text in
            self?.operationStatus = text
            self?.refreshStatus()
        }
        monitor.onState = { [weak self] active in
            if active { self?.operationStatus = "Готово · клавиатура подключена" }
            self?.refreshStatus()
        }
        monitor.start()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.monitor.start()
            self.refreshStatus()
            if self.preferences?.window?.isVisible == true { self.preferences?.refreshLoginItem() }
        }
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.async {
                if !self.monitor.active { self.requestAccess() }
                else { self.showHelp() }
            }
        }
    }
    private func refreshStatus() {
        let needsAccess = !monitor.active
        statusItem.action = needsAccess ? #selector(requestAccess) : nil
        statusItem.isEnabled = needsAccess
        if needsAccess {
            statusItem.title = "Нет доступа · нажмите, чтобы разрешить"
        } else if IsSecureEventInputEnabled() {
            statusItem.title = "Защищённый ввод · исправление недоступно"
        } else if !monitor.enabled {
            statusItem.title = "Исправление приостановлено"
        } else {
            statusItem.title = operationStatus
        }
    }
    @objc private func toggle() {
        monitor.enabled.toggle()
        enabledItem.state = monitor.enabled ? .on : .off
        if monitor.enabled { operationStatus = "Готово · клавиатура подключена" }
        refreshStatus()
    }
    @objc private func showPreferences() {
        if preferences == nil {
            let controller = PreferencesController(shortcut: monitor.shortcut, exclusions: monitor.exclusions)
            controller.onChange = { [weak self] shortcut, exclusions in
                guard let self = self else { return }
                self.monitor.shortcut = shortcut; self.monitor.exclusions = exclusions
                UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut")
                UserDefaults.standard.set(try? JSONEncoder().encode(exclusions), forKey: "excludedApplications")
                self.operationStatus = "Настройки сохранены"
                self.refreshStatus()
            }
            controller.onRecordingChange = { [weak self] value in self?.monitor.recording = value }
            preferences = controller
        }
        preferences?.showWindow(nil)
        preferences?.refreshLoginItem()
        NSApp.activate(ignoringOtherApps: true)
        preferences?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ControlFlip"
        alert.informativeText = "Назначено: \(monitor.shortcut.displayName).\n\nКак исправить текст:\n1. Оставьте курсор после слова, набранного не в той раскладке, или выделите нужный фрагмент.\n2. Коротко нажмите и отпустите назначенную клавишу или сочетание. По умолчанию — левый Control.\n3. ControlFlip исправит текст и переключит раскладку для дальнейшего набора.\n\nНапример: ghbdtn → привет — дальше вы печатаете по-русски. Руддщ → Hello — дальше по-английски. Если ничего не выделено, исправляется последнее слово перед курсором; пробелы после него сохраняются. Автоматических замен при наборе нет.\n\nСвои клавиши: а/я → Настройки → Записать сочетание. В настройках также доступны исключения программ и автозапуск.\n\nДля работы добавьте русскую и английскую раскладки в macOS и разрешите Универсальный доступ. Если доступа нет, нажмите верхнюю строку «Нет доступа» в меню а/я.\n\nВ некоторых редакторах нужно выделить текст вручную. В полях паролей исправление не работает. Буфер обмена временно используется при замене и затем восстанавливается. Набранный текст не сохраняется на диск и не отправляется в сеть."
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
    }
    @objc private func requestAccess() {
        guard !monitor.active else { refreshStatus(); return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // This is the posting privilege, which also permits listening. A stale
        // AX boolean must not prevent the actual system access request.
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        monitor.start()
        refreshStatus()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--login-item-info") {
    print("SMAppService API available: \(CFLoginItemAPIAvailable())")
    print("Login item status: \(CFLoginItemStatus())")
    exit(CFLoginItemAPIAvailable() ? 0 : 1)
}

if CommandLine.arguments.contains("--self-test") {
    let layouts = InputLayouts()
    let forward = layouts.converter.convert("Ghbdtn vbh")?.text == "Привет мир"
    let backward = layouts.converter.convert("Руддщ цщкдв")?.text == "Hello world"
    let board = NSPasteboard(name: NSPasteboard.Name("local.controlflip.selftest.\(UUID().uuidString)"))
    let original = NSPasteboardItem()
    let customType = NSPasteboard.PasteboardType("local.controlflip.test")
    let payload = Data([0, 1, 2, 255])
    original.setString("clipboard before conversion", forType: .string)
    original.setData(payload, forType: customType)
    let clipboardAvailable = board.writeObjects([original]) && board.string(forType: .string) == "clipboard before conversion"
    if !clipboardAvailable {
        print("Installed English source: \(layouts.english != nil)")
        print("Installed Russian source: \(layouts.russian != nil)")
        print("System layout conversion: \(forward && backward ? "PASS" : "FAIL")")
        print("Clipboard tests: SKIPPED (pasteboard service unavailable in this execution environment)")
        print("Accessibility permission: \(AXIsProcessTrusted())")
        board.releaseGlobally()
        exit(forward && backward ? 2 : 1)
    }
    let snapshot = ClipboardSnapshot(board)
    board.clearContents(); board.setString("temporary text", forType: .string)
    snapshot.restore(board, ifUnchanged: board.changeCount)
    let restored = board.string(forType: .string) == "clipboard before conversion" && board.data(forType: customType) == payload
    let savedCount = board.changeCount
    board.clearContents(); board.setString("new clipboard from user", forType: .string)
    snapshot.restore(board, ifUnchanged: savedCount)
    let respected = board.string(forType: .string) == "new clipboard from user"
    board.releaseGlobally()
    print("Installed English source: \(layouts.english != nil)")
    print("Installed Russian source: \(layouts.russian != nil)")
    print("System layout conversion: \(forward && backward ? "PASS" : "FAIL")")
    print("Clipboard formats restored: \(restored ? "PASS" : "FAIL")")
    print("Concurrent clipboard change preserved: \(respected ? "PASS" : "FAIL")")
    print("Accessibility permission: \(AXIsProcessTrusted())")
    exit(forward && backward && restored && respected ? 0 : 1)
}

private let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()
