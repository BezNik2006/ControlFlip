import Cocoa

final class PreferencesController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: ((ShortcutSpec, [ExcludedApplication]) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var shortcut: ShortcutSpec
    private var exclusions: [ExcludedApplication]
    private var candidate: ShortcutSpec?
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let recordButton = NSButton(title: "Записать сочетание…", target: nil, action: nil)
    private let saveButton = NSButton(title: "Сохранить сочетание", target: nil, action: nil)
    private let table = NSTableView()
    private var eventMonitor: Any?
    private var commitTimer: Timer?
    private var held: Set<Int> = []
    private var gesture: Set<Int> = []
    private var previousTap: (Int, TimeInterval)?
    private var recording = false
    private let loginCheckbox = NSButton(checkboxWithTitle: "Запускать при входе в macOS", target: nil, action: nil)
    private let loginDescription = NSTextField(wrappingLabelWithString: "")

    init(shortcut: ShortcutSpec, exclusions: [ExcludedApplication]) {
        self.shortcut = shortcut; self.exclusions = exclusions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 510),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Настройки ControlFlip"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        guard let view = window.contentView else { return }
        func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 24, bold: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.frame = NSRect(x: x, y: y, width: width, height: height)
            if bold { field.font = NSFont.boldSystemFont(ofSize: 14) }
            view.addSubview(field)
        }
        label("Клавиши для исправления раскладки", x: 24, y: 464, width: 600, bold: true)
        shortcutLabel.frame = NSRect(x: 24, y: 429, width: 600, height: 27)
        shortcutLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        shortcutLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(shortcutLabel)
        recordButton.frame = NSRect(x: 20, y: 382, width: 224, height: 34)
        recordButton.bezelStyle = .rounded; recordButton.target = self; recordButton.action = #selector(toggleRecording)
        view.addSubview(recordButton)
        saveButton.frame = NSRect(x: 252, y: 382, width: 224, height: 34)
        saveButton.bezelStyle = .rounded; saveButton.target = self; saveButton.action = #selector(saveShortcut)
        saveButton.isEnabled = false; view.addSubview(saveButton)
        hint.frame = NSRect(x: 24, y: 312, width: 600, height: 63)
        hint.font = NSFont.systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        view.addSubview(hint)
        label("Не исправлять текст в этих программах", x: 24, y: 274, width: 600, bold: true)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 84, width: 602, height: 184))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.title = "Программа"; column.width = 565
        table.addTableColumn(column); table.headerView = nil
        table.rowHeight = 30; table.delegate = self; table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table; view.addSubview(scroll)
        let add = NSButton(title: "Добавить программу…", target: self, action: #selector(addApplication))
        add.frame = NSRect(x: 20, y: 35, width: 220, height: 34); add.bezelStyle = .rounded; view.addSubview(add)
        let remove = NSButton(title: "Убрать из исключений", target: self, action: #selector(removeApplication))
        remove.frame = NSRect(x: 246, y: 35, width: 220, height: 34); remove.bezelStyle = .rounded; view.addSubview(remove)
        updateDescription()
        // Reserve a separate area below the existing keyboard and app settings.
        window.setContentSize(NSSize(width: 650, height: 600))
        for child in view.subviews { var frame = child.frame; frame.origin.y += 90; child.frame = frame }
        loginCheckbox.frame = NSRect(x: 24, y: 50, width: 410, height: 26)
        loginCheckbox.target = self; loginCheckbox.action = #selector(toggleLoginItem)
        view.addSubview(loginCheckbox)
        let loginSettings = NSButton(title: "Объекты входа…", target: self, action: #selector(openLoginSettings))
        loginSettings.frame = NSRect(x: 446, y: 48, width: 180, height: 32)
        loginSettings.bezelStyle = .rounded; view.addSubview(loginSettings)
        loginDescription.frame = NSRect(x: 24, y: 10, width: 602, height: 34)
        loginDescription.font = NSFont.systemFont(ofSize: 12)
        loginDescription.textColor = .secondaryLabelColor
        view.addSubview(loginDescription)
        refreshLoginItem(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func refreshLoginItem() {
        let manager = LoginItemManager.shared
        switch manager.state {
        case .enabled: loginCheckbox.state = .on
        case .requiresApproval: loginCheckbox.state = .mixed
        default: loginCheckbox.state = .off
        }
        loginCheckbox.isEnabled = manager.state != .unavailable
        loginDescription.stringValue = manager.description
    }
    @objc private func toggleLoginItem() {
        let manager = LoginItemManager.shared
        let shouldEnable = manager.state != .enabled && manager.state != .requiresApproval
        if !manager.setEnabled(shouldEnable) {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = manager.lastError ?? "Проверьте настройку в macOS → Основные → Объекты входа."
            alert.runModal()
        }
        refreshLoginItem()
    }
    @objc private func openLoginSettings() { LoginItemManager.shared.openSettings() }

    private func updateDescription() {
        shortcutLabel.stringValue = (candidate ?? shortcut).displayName
        hint.stringValue = "Нажмите «Записать», затем своё сочетание. Можно назначить Control, несколько модификаторов, клавишу с Command/Option/Control/Shift или двойное нажатие одного модификатора. Левая и правая стороны различаются."
    }
    @objc private func toggleRecording() {
        if recording { stopRecording(); candidate = nil; updateDescription(); return }
        candidate = nil; held = []; gesture = []; previousTap = nil
        recording = true; onRecordingChange?(true)
        saveButton.isEnabled = false
        recordButton.title = "Отменить запись (Esc)"
        shortcutLabel.stringValue = "Нажмите нужные клавиши…"
        hint.stringValue = "Нажмите и отпустите своё сочетание. Для двойного нажатия повторите одну клавишу-модификатор быстро, в пределах 0,4 секунды. Системные сочетания macOS могут иметь приоритет."
        window?.makeFirstResponder(nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self, self.recording else { return event }
            self.capture(event)
            return nil
        }
    }
    private func stopRecording() {
        commitTimer?.invalidate(); commitTimer = nil
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
        recording = false; onRecordingChange?(false)
        recordButton.title = "Записать сочетание…"
        saveButton.isEnabled = candidate != nil
    }
    private func captured(_ value: ShortcutSpec) {
        guard value.isValid else { return }
        candidate = value; stopRecording()
        shortcutLabel.stringValue = value.displayName
        hint.stringValue = value.keyCode != nil && value.modifiers.isEmpty
            ? "Выбрана одиночная клавиша. Она будет перехватываться в программах, кроме исключений. Нажмите «Сохранить сочетание», чтобы применить."
            : "Нажмите «Сохранить сочетание», чтобы применить. До сохранения действует прежнее сочетание."
    }
    private func capture(_ event: NSEvent) {
        let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
        let now = ShortcutSpec.pressedModifiers(flags)
        let code = Int(event.keyCode)
        if event.type == .keyDown {
            if code == 53 && now.isEmpty { stopRecording(); candidate = nil; updateDescription(); return }
            captured(ShortcutSpec(keyCode: code, modifiers: now.sorted(), tapCount: 1))
        } else if event.type == .flagsChanged {
            if code == 57 { return } // Caps Lock is a toggle, not a held modifier.
            commitTimer?.invalidate(); commitTimer = nil
            if held.isEmpty && !now.isEmpty { gesture = [] }
            gesture.formUnion(now)
            let released = !held.isEmpty && now.isEmpty
            held = now
            guard released, !gesture.isEmpty else { return }
            let keys = gesture.sorted()
            if keys.count > 1 {
                captured(ShortcutSpec(keyCode: nil, modifiers: keys, tapCount: 1)); return
            }
            if let previous = previousTap, previous.0 == keys[0], event.timestamp - previous.1 <= 0.4 {
                captured(ShortcutSpec(keyCode: nil, modifiers: keys, tapCount: 2)); return
            }
            previousTap = (keys[0], event.timestamp)
            let value = ShortcutSpec(keyCode: nil, modifiers: keys, tapCount: 1)
            shortcutLabel.stringValue = value.displayName
            commitTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in self?.captured(value) }
        }
    }
    @objc private func saveShortcut() {
        guard let value = candidate, value.isValid else { return }
        shortcut = value; candidate = nil; saveButton.isEnabled = false
        onChange?(shortcut, exclusions)
        updateDescription(); hint.stringValue = "Сочетание сохранено. Настройки сохраняются и после перезапуска приложения."
    }
    @objc private func addApplication() {
        if recording { stopRecording(); candidate = nil; updateDescription() }
        let panel = NSOpenPanel()
        panel.title = "Выберите программы для исключений"
        panel.prompt = "Добавить"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedFileTypes = ["app"]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false; panel.allowsMultipleSelection = true
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK else { return }
            for url in panel.urls {
                let bundle = Bundle(url: url)
                let identity = ExcludedApplication.identity(bundleIdentifier: bundle?.bundleIdentifier, path: url.path)
                if self.exclusions.contains(where: { $0.identifier == identity }) { continue }
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                self.exclusions.append(ExcludedApplication(identifier: identity, name: name, path: url.path))
            }
            self.exclusions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.table.reloadData(); self.onChange?(self.shortcut, self.exclusions)
        }
    }
    @objc private func removeApplication() {
        let row = table.selectedRow
        guard row >= 0 && row < exclusions.count else { return }
        exclusions.remove(at: row); table.reloadData(); onChange?(shortcut, exclusions)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { return exclusions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: exclusions[row].name)
        label.toolTip = exclusions[row].path
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    func windowWillClose(_ notification: Notification) { stopRecording(); candidate = nil; updateDescription() }
    func windowDidResignKey(_ notification: Notification) {
        if recording { stopRecording(); candidate = nil; updateDescription() }
    }
}
