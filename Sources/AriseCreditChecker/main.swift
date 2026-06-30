// AriseCreditChecker — a native macOS menu bar app.
//
// Tracks remaining credit across one or more Arise (LiteLLM) API keys.
// Each account polls GET {base_url}/key/info with a Bearer token; per-account
// remaining = max_budget − spend (or shows spent when uncapped).
//
// Built with AppKit: NSStatusItem + NSMenu. Single-file, no dependencies.

import AppKit
import Foundation

// MARK: - Constants

let appName = "Arise Credit"
let defaultBaseURL = "https://arise-lite-llm-gw-1.arisetech.dev"
let endpoint = "/key/info"
let pollInterval: TimeInterval = 300 // 5 minutes

// MARK: - Models

struct Account: Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
}

struct Settings: Codable {
    var accounts: [Account] = []
    var lastRefresh: Date?
}

struct KeyInfo: Decodable {
    // LiteLLM wraps data; we walk key_info -> token (or info -> token) in fetch.
    let keyAlias: String?
    let spend: Double?
    let maxBudget: Double?
    let models: [String]?

    enum CodingKeys: String, CodingKey {
        case keyAlias = "key_alias"
        case spend
        case maxBudget = "max_budget"
        case models
    }

    /// Manual init from a raw JSON dictionary so we can also pull
    /// `max_budget` out of the nested `litellm_budget_table` object that
    /// some LiteLLM deployments put it under.
    init?(from dict: [String: Any]) {
        self.keyAlias = dict["key_alias"] as? String
        self.spend = (dict["spend"] as? Double) ?? (dict["spend"] as? NSNumber)?.doubleValue
        // max_budget can live at the top level OR under litellm_budget_table.
        if let mb = dict["max_budget"] as? Double {
            self.maxBudget = mb
        } else if let mb = (dict["max_budget"] as? NSNumber)?.doubleValue {
            self.maxBudget = mb
        } else if let budget = dict["litellm_budget_table"] as? [String: Any] {
            if let mb = budget["max_budget"] as? Double {
                self.maxBudget = mb
            } else {
                self.maxBudget = (budget["max_budget"] as? NSNumber)?.doubleValue
            }
        } else {
            self.maxBudget = nil
        }
        self.models = dict["models"] as? [String]
    }
}

enum FetchError: Error, LocalizedError {
    case http(Int, String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let reason): return "HTTP \(code) \(reason)"
        case .other(let m): return m
        }
    }
}

// MARK: - Settings store

/// JSON persistence in ~/Library/Application Support/Arise Credit/settings.json
final class SettingsStore {
    static let shared = SettingsStore()

    private let url: URL = {
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory,
                               in: .userDomainMask,
                               appropriateFor: nil,
                               create: true)
        let dir = base.appendingPathComponent("Arise Credit", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    private let queue = DispatchQueue(label: "settings.io")

    func load() -> Settings {
        var s = Settings()
        guard let data = try? Data(contentsOf: url) else { return s }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(Settings.self, from: data) {
            s = decoded
        }
        return s
    }

    func save(_ settings: Settings) {
        queue.async { [url] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(settings) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - API

func fetchKeyInfo(baseURL: String, apiKey: String, completion: @escaping (Result<KeyInfo, FetchError>) -> Void) {
    guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + endpoint) else {
        completion(.failure(.other("invalid URL")))
        return
    }
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.httpMethod = "GET"
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")

    let task = URLSession.shared.dataTask(with: req) { data, response, error in
        if let error = error {
            completion(.failure(.other(error.localizedDescription)))
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completion(.failure(.other("no response")))
            return
        }
        guard (200...299).contains(http.statusCode) else {
            completion(.failure(.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))))
            return
        }
        guard let data = data else {
            completion(.failure(.other("empty body")))
            return
        }
        // Parse the LiteLLM envelope. Try every known shape in order and
        // surface the REAL error (not a swallowed one) so failures are debuggable.
        let parse: (Data) -> Result<KeyInfo, FetchError> = { data in
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.other("response is not a JSON object"))
            }
            // Dump the raw payload to Application Support so any future
            // parse failure is inspectable.
            dumpDebug(root)

            // Candidates for the "token" object holding spend/budget.
            // LiteLLM has used several envelopes across versions.
            let envelope = (root["key_info"] as? [String: Any])
                            ?? (root["info"] as? [String: Any])
                            ?? root
            let tokenCandidates: [[String: Any]] = [
                (envelope["token"] as? [String: Any]) ?? [:],
                envelope,   // sometimes the fields sit directly under info
                root,       // sometimes no envelope at all
            ]
            for candidate in tokenCandidates where !candidate.isEmpty {
                if let info = KeyInfo(from: candidate) {
                    return .success(info)
                }
            }
            return .failure(.other("could not find spend/budget in response (see debug dump)"))
        }
        completion(parse(data))
    }
    task.resume()
}

/// Write the raw parsed response to ~/Library/Application Support/Arise Credit/
/// last_response.json for debugging when a parse fails.
private func dumpDebug(_ root: [String: Any]) {
    guard let url = debugDumpURL else { return }
    if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}

private var debugDumpURL: URL? = {
    let fm = FileManager.default
    guard let base = try? fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask, appropriateFor: nil, create: true) else {
        return nil
    }
    let dir = base.appendingPathComponent("Arise Credit", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("last_response.json")
}()

// MARK: - Account state

enum AccountState {
    case loading, ok, warn, danger, uncapped, error(String)
}

func state(for info: KeyInfo?, error: FetchError?) -> AccountState {
    if let error = error { return .error(error.errorDescription ?? "error") }
    guard let info = info else { return .loading }
    if let max = info.maxBudget, let spend = info.spend {
        let pct = max > 0 ? spend / max * 100 : 0
        if pct >= 90 { return .danger }
        if pct >= 70 { return .warn }
        return .ok
    }
    if info.spend != nil { return .uncapped }
    return .loading
}

func remaining(for info: KeyInfo?) -> Double? {
    guard let info = info, let max = info.maxBudget, let spend = info.spend else { return nil }
    return max - spend
}

// MARK: - Formatting

func fmt(_ n: Double?) -> String {
    guard let n = n else { return "—" }
    return NumberFormatter.localizedString(from: NSNumber(value: n), number: .currency)
}

func glyph(for state: AccountState) -> String {
    switch state {
    case .ok: return "🟢"
    case .warn: return "🟡"
    case .danger: return "🔴"
    case .uncapped: return "🔵"
    case .error: return "⚠️"
    case .loading: return "⏳"
    }
}

// MARK: - Menu builder

final class CreditChecker {
    private let statusItem: NSStatusItem
    private var settings = SettingsStore.shared.load()
    // Per-account fetched results (nil = not yet loaded).
    private var results: [String: Result<KeyInfo, FetchError>] = [:]

    // Cached menu items so we can mutate titles in place.
    private var headerItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    private var accountSubmenus: [String: NSMenuItem] = [:]
    private let accountsMenuItem = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
    private var accountsSeparator: NSMenuItem = NSMenuItem.separator()
    private let addItem = NSMenuItem(title: "Add account…", action: #selector(onAdd), keyEquivalent: "n")
    private let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(onRefresh), keyEquivalent: "r")
    private let quitItem = NSMenuItem(title: "Quit Arise Credit", action: #selector(onQuit), keyEquivalent: "q")

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏳"
        buildMenu()
    }

    // MARK: menu construction
    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        accountsMenuItem.submenu = NSMenu()
        accountsMenuItem.isEnabled = true
        menu.addItem(accountsMenuItem)
        menu.addItem(.separator())

        addItem.target = self
        refreshItem.target = self
        quitItem.target = self
        menu.addItem(addItem)
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        render()
    }

    @objc private func onQuit() {
        NSApp.terminate(nil)
    }

    // MARK: actions
    @objc private func onRefresh() {
        refreshAll()
    }

    @objc private func onAdd() {
        AccountEditor.present(mode: .add) { [weak self] result in
            guard let self = self, let result = result else { return }
            var id = "acc-\(self.settings.accounts.count + 1)"
            var n = self.settings.accounts.count + 1
            while self.settings.accounts.contains(where: { $0.id == id }) {
                n += 1
                id = "acc-\(n)"
            }
            self.settings.accounts.append(Account(id: id, name: result.name, baseURL: result.baseURL, apiKey: result.apiKey))
            SettingsStore.shared.save(self.settings)
            self.refreshAll()
        }
    }

    @objc private func onEdit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let account = settings.accounts.first(where: { $0.id == id }) else { return }
        AccountEditor.present(mode: .edit(account)) { [weak self] result in
            guard let self = self, let result = result,
                  let idx = self.settings.accounts.firstIndex(where: { $0.id == id }) else { return }
            var updated = self.settings.accounts[idx]
            updated.name = result.name
            updated.baseURL = result.baseURL
            if !result.apiKey.isEmpty { updated.apiKey = result.apiKey }
            self.settings.accounts[idx] = updated
            SettingsStore.shared.save(self.settings)
            self.refreshAll()
        }
    }

    @objc private func onRemove(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let account = settings.accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(account.name)”?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.accounts.removeAll { $0.id == id }
            results.removeValue(forKey: id)
            SettingsStore.shared.save(settings)
            render()
        }
    }

    // MARK: polling
    func refreshAll() {
        if settings.accounts.isEmpty {
            render()
            return
        }
        for account in settings.accounts {
            fetchKeyInfo(baseURL: account.baseURL, apiKey: account.apiKey) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.results[account.id] = result
                    // Re-render as each result lands.
                    self.render()
                }
            }
        }
        settings.lastRefresh = Date()
        SettingsStore.shared.save(settings)
    }

    // MARK: render
    func render() {
        renderHeader()
        renderAccounts()
        renderStatusTitle()
    }

    private func renderHeader() {
        if settings.accounts.isEmpty {
            headerItem.title = "No accounts — Add account…"
            return
        }
        var totalRem: Double = 0, totalUncapped: Double = 0
        var hasRem = false, hasUncapped = false
        var errors = 0
        for account in settings.accounts {
            switch results[account.id] {
            case .none: break
            case .failure: errors += 1
            case .success(let info):
                if let rem = remaining(for: info) { totalRem += rem; hasRem = true }
                else if let spend = info.spend { totalUncapped += spend; hasUncapped = true }
            }
        }
        var parts: [String] = []
        if hasRem { parts.append("\(fmt(totalRem)) remaining") }
        if hasUncapped { parts.append("\(fmt(totalUncapped)) spent (uncapped)") }
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        headerItem.title = parts.isEmpty ? "Loading…   ·   updated \(ts)"
                                      : parts.joined(separator: " · ") + "   ·   updated \(ts)"
    }

    private func renderAccounts() {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if settings.accounts.isEmpty {
            let item = NSMenuItem(title: "No accounts yet — use “Add account…”", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        } else {
            for account in settings.accounts {
                submenu.addItem(buildAccountRow(for: account))
            }
        }
        accountsMenuItem.submenu = submenu
    }

    private func buildAccountRow(for account: Account) -> NSMenuItem {
        let result = results[account.id]
        let info: KeyInfo? = { if case .success(let i) = result { return i } else { return nil } }()
        let err: FetchError? = { if case .failure(let e) = result { return e } else { return nil } }()
        let st = state(for: info, error: err)

        let balance: String
        switch st {
        case .loading: balance = "…"
        case .error(let m): balance = "⚠ \(m)"
        default:
            if let rem = remaining(for: info) { balance = fmt(rem) }
            else if let spend = info?.spend { balance = "\(fmt(spend)) spent" }
            else { balance = "—" }
        }
        // Tab-align the balance toward the right using a tab + a right tab stop.
        let title = "\(glyph(for: st))  \(account.name)\t\(balance)"

        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        head.isEnabled = true

        // Detail submenu.
        let detail = NSMenu()
        detail.autoenablesItems = false
        if case .error(let m) = st {
            let item = NSMenuItem(title: "Error: \(m)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            detail.addItem(item)
        } else {
            addDetail(detail, "Remaining:", fmt(remaining(for: info)))
            addDetail(detail, "Spent:",     fmt(info?.spend))
            addDetail(detail, "Budget:",    info?.maxBudget == nil ? "unlimited" : fmt(info?.maxBudget))
            if let max = info?.maxBudget, let spend = info?.spend, max > 0 {
                addDetail(detail, "Used:", String(format: "%.1f%%", spend / max * 100))
            }
            addDetail(detail, "Alias:", info?.keyAlias ?? "—")
            let models = info?.models ?? []
            addDetail(detail, "Models:", models.isEmpty ? "all" : models.joined(separator: ", "))
        }
        detail.addItem(.separator())
        let editItem = NSMenuItem(title: "Edit…", action: #selector(onEdit), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = account.id
        let removeItem = NSMenuItem(title: "Remove", action: #selector(onRemove), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = account.id
        detail.addItem(editItem)
        detail.addItem(removeItem)

        head.submenu = detail
        return head
    }

    private func addDetail(_ menu: NSMenu, _ k: String, _ v: String) {
        let item = NSMenuItem(title: "\(k)\t\(v)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func renderStatusTitle() {
        if settings.accounts.isEmpty {
            statusItem.button?.title = "🔑"
            return
        }
        var totalRem: Double = 0
        var hasRem = false
        var errors = 0
        for account in settings.accounts {
            switch results[account.id] {
            case .none: break
            case .failure: errors += 1
            case .success(let info):
                if let rem = remaining(for: info) { totalRem += rem; hasRem = true }
            }
        }
        if hasRem {
            statusItem.button?.title = fmt(totalRem) + (errors > 0 ? " ⚠️" : "")
        } else if errors > 0 {
            statusItem.button?.title = "⚠️"
        } else {
            statusItem.button?.title = "…"
        }
    }
}

// MARK: - Account editor (native sheet)

final class AccountEditor: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    enum Mode {
        case add
        case edit(Account)
    }

    private let window: NSWindow
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let keyField = NSSecureTextField()
    private let mode: Mode
    private let completion: (Result?) -> Void

    struct Result { let name, baseURL, apiKey: String }

    private init(mode: Mode, completion: @escaping (Result?) -> Void) {
        self.mode = mode
        self.completion = completion
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.center()
        super.init()
        window.delegate = self
        build()
    }

    static func present(mode: Mode, completion: @escaping (Result?) -> Void) {
        let editor = AccountEditor(mode: mode, completion: completion)
        // Keep alive until the sheet closes.
        editor.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        objc_setAssociatedObject(editor.window, &assocKey, editor, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var assocKey: UInt8 = 0

    private func build() {
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let (initialName, initialURL, keyPlaceholder, title) : (String, String, String, String) = {
            switch mode {
            case .add: return ("", defaultBaseURL, "Bearer token", "Add account")
            case .edit(let a): return (a.name, a.baseURL, "leave blank to keep current", "Edit account")
            }
        }()

        window.title = title
        nameField.stringValue = initialName
        nameField.placeholderString = "Work, Personal, Staging…"
        urlField.stringValue = initialURL
        urlField.placeholderString = "https://…"
        keyField.placeholderString = keyPlaceholder

        let stack = NSStackView(views: [
            labeledRow("Name", nameField),
            labeledRow("Gateway URL", urlField),
            labeledRow("API key", keyField),
        ])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let buttons = NSStackView(views: [saveButton(), cancelButton()])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func labeledRow(_ label: String, _ field: NSControl) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [lbl, field])
        row.orientation = .horizontal
        row.spacing = 12
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return row
    }

    private func saveButton() -> NSButton {
        let b = NSButton(title: "Save", target: self, action: #selector(save))
        b.keyEquivalent = "\r"
        b.bezelStyle = .rounded
        if #available(macOS 10.14, *) { b.controlSize = .large }
        return b
    }
    private func cancelButton() -> NSButton {
        let b = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        b.keyEquivalent = "\u{1b}"
        b.bezelStyle = .rounded
        if #available(macOS 10.14, *) { b.controlSize = .large }
        return b
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        let key = keyField.stringValue
        let finalName = name.isEmpty ? "Account" : name
        let finalURL = url.isEmpty ? defaultBaseURL : url
        if case .add = mode, key.trimmingCharacters(in: .whitespaces).isEmpty {
            flash(keyField)
            return
        }
        let result = Result(name: finalName, baseURL: finalURL, apiKey: key)
        finish(result)
    }
    @objc private func cancel() { finish(nil) }

    private func finish(_ result: Result?) {
        completion(result)
        window.sheetParent?.endSheet(window)
        window.close()
        objc_setAssociatedObject(window, &AccountEditor.assocKey, nil, .OBJC_ASSOCIATION_RETAIN)
        NSApp.hide(nil)
    }

    private func flash(_ field: NSTextField) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            field.animator().backgroundColor = NSColor(calibratedRed: 1, green: 0.4, blue: 0.4, alpha: 0.4)
        } completionHandler: {
            field.backgroundColor = NSColor.textBackgroundColor
        }
    }
}

// MARK: - App entry point

final class AppDelegate: NSObject, NSApplicationDelegate {
    let checker = CreditChecker()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One immediate refresh + a repeating timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checker.refreshAll()
        }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checker.refreshAll()
        }
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no dock icon, menu bar only
app.run()
