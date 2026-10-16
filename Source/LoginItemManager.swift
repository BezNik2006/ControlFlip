import Cocoa

enum LoginItemState: Int {
    case unavailable = -1, notRegistered = 0, enabled = 1, requiresApproval = 2, notFound = 3
}

final class LoginItemManager {
    static let shared = LoginItemManager()
    private(set) var lastError: String?
    var state: LoginItemState { return LoginItemState(rawValue: CFLoginItemStatus()) ?? .unavailable }
    var installed: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
    var description: String {
        switch state {
        case .enabled: return "ControlFlip будет запускаться при входе в вашу учётную запись."
        case .requiresApproval: return "Подтвердите ControlFlip в системных настройках «Объекты входа»."
        case .notRegistered: return lastError ?? "Автозапуск выключен."
        case .notFound: return lastError ?? "Перенесите ControlFlip в «Программы», затем включите автозапуск."
        case .unavailable: return "Системная служба автозапуска недоступна."
        }
    }
    // The user requested startup for this personal app. Register once after
    // installation, and respect later changes in macOS instead of re-enabling it.
    func enableInitiallyIfNeeded() {
        let key = "launchAtLoginConfigured"
        guard installed, UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        _ = setEnabled(true)
    }
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        if enabled && !installed {
            lastError = "Сначала перенесите ControlFlip в папку «Программы» и запустите оттуда."
            return false
        }
        let current = state
        if enabled && current == .enabled { return true }
        if !enabled && current == .notRegistered { return true }
        if enabled && current == .requiresApproval { CFLoginItemOpenSettings(); return true }
        var error: NSError?
        let result = CFLoginItemSetEnabled(enabled, &error)
        if !result { lastError = error?.localizedDescription ?? "macOS не изменила автозапуск." }
        else { UserDefaults.standard.set(true, forKey: "launchAtLoginConfigured") }
        return result
    }
    func openSettings() { CFLoginItemOpenSettings() }
}
