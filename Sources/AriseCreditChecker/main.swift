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

// Accent colors matching the redesign mockup
let accentOK      = NSColor(red: 16/255, green: 185/255, blue: 129/255, alpha: 1)  // #10b981
let accentWarn    = NSColor(red: 245/255, green: 158/255, blue: 11/255, alpha: 1)  // #f59e0b
let accentDanger  = NSColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1)   // #ef4444
let accentUncapped = NSColor(red: 59/255, green: 130/255, blue: 246/255, alpha: 1) // #3b82f6

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
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: n)) ?? "—"
}

func coloredCircle(color: NSColor, size: CGFloat = 10) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    color.set()
    let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size))
    path.fill()
    image.unlockFocus()
    image.isTemplate = false
    return image
}

func statusDot(for state: AccountState) -> NSImage? {
    switch state {
    case .ok:
        return coloredCircle(color: accentOK)
    case .warn:
        return coloredCircle(color: accentWarn)
    case .danger:
        return coloredCircle(color: accentDanger)
    case .uncapped:
        return coloredCircle(color: accentUncapped)
    case .error:
        return symbolImage("exclamationmark.triangle.fill", description: "Error")
    case .loading:
        return symbolImage("hourglass", description: "Loading")
    }
}

func symbolImage(_ name: String, description: String, color: NSColor? = nil) -> NSImage? {
    if let color = color {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    } else {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description) else {
            return nil
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Menu builder

final class CreditChecker: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var settings = SettingsStore.shared.load()
    // Per-account fetched results (nil = not yet loaded).
    private var results: [String: Result<KeyInfo, FetchError>] = [:]
    // Pulse animation state
    private var pulseTimer: Timer?
    private var pulseAlpha: CGFloat = 1.0
    private var pulseDirection: CGFloat = -1  // -1 fading out, +1 fading in
    private weak var headerValueItem: NSMenuItem?
    private var headerMainText: String = ""
    private var headerTimeText: String = ""

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = symbolImage("hourglass", description: "Loading")
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

    private func getGlobalHeaderItems() -> [NSMenuItem] {
        if settings.accounts.isEmpty {
            let item = NSMenuItem(title: "No accounts — Add account…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return [item]
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
        
        let headerLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let labelAttr = NSAttributedString(string: "TOTAL CREDIT", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.3
        ])
        headerLabel.view = InfoMenuItemView(leftAttr: labelAttr)
        headerLabel.isEnabled = true
        
        var mainText = "Loading…"
        if hasRem || hasUncapped || errors > 0 {
            var parts: [String] = []
            if hasRem { parts.append("\(fmt(totalRem)) remaining") }
            if hasUncapped { parts.append("\(fmt(totalUncapped)) spent (uncapped)") }
            if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
            mainText = parts.joined(separator: " · ")
        }
        
        headerMainText = mainText
        let updatedStr = getUpdatedTimeText()
        headerTimeText = updatedStr
        
        let headerValue = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let leftAttr = NSAttributedString(string: mainText, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.white
        ])
        let rightAttr = NSAttributedString(string: updatedStr, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(pulseAlpha)
        ])
        
        let valView = InfoMenuItemView(leftAttr: leftAttr, rightAttr: rightAttr, rightInset: 10, topInset: 3, bottomInset: 3, height: 28)
        headerValue.view = valView
        headerValue.isEnabled = true
        headerValueItem = headerValue
        
        return [headerLabel, headerValue]
    }

    private func getUpdatedTimeText() -> String {
        guard let lastRefresh = settings.lastRefresh else {
            return "Updated never"
        }
        let minutes = Int(Date().timeIntervalSince(lastRefresh) / 60)
        if minutes == 0 {
            return "Updated just now"
        } else {
            return "Updated \(minutes)m ago"
        }
    }

    // MARK: render
    func render() {
        renderStatusTitle()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 300
        menu.delegate = self

        // 1. Header
        let headers = getGlobalHeaderItems()
        for h in headers { menu.addItem(h) }
        
        menu.addItem(.separator())

        // 2. Accounts
        if !settings.accounts.isEmpty {
            let activeLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let activeAttr = NSAttributedString(string: "ACTIVE ACCOUNTS", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.5
            ])
            activeLabel.view = InfoMenuItemView(leftAttr: activeAttr)
            activeLabel.isEnabled = true
            menu.addItem(activeLabel)
            
            for account in settings.accounts {
                menu.addItem(buildAccountRow(for: account))
            }
        }
        menu.addItem(.separator())

        // 3. Actions
        let add = NSMenuItem(title: "", action: #selector(onAdd), keyEquivalent: "n")
        add.target = self
        add.view = ActionMenuItemView(name: "Add account", shortcut: "⌘N", icon: symbolImage("plus.circle", description: "Add account"))
        add.isEnabled = true
        menu.addItem(add)

        let refresh = NSMenuItem(title: "", action: #selector(onRefresh), keyEquivalent: "r")
        refresh.target = self
        refresh.view = ActionMenuItemView(name: "Refresh now", shortcut: "⌘R", icon: symbolImage("arrow.clockwise", description: "Refresh now"))
        refresh.isEnabled = true
        menu.addItem(refresh)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        quit.view = ActionMenuItemView(name: "Quit Arise Credit", shortcut: "⌘Q", icon: symbolImage("power", description: "Quit"))
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func buildAccountRow(for account: Account) -> NSMenuItem {
        let result = results[account.id]
        let info: KeyInfo? = { if case .success(let i) = result { return i } else { return nil } }()
        let err: FetchError? = { if case .failure(let e) = result { return e } else { return nil } }()
        let st = state(for: info, error: err)

        let balance: String
        var balanceColor: NSColor = .labelColor
        switch st {
        case .loading: balance = "…"
        case .error(_): 
            balance = "⚠ Error"
            balanceColor = accentDanger
        default:
            if let rem = remaining(for: info) { 
                balance = fmt(rem)
                balanceColor = accentOK
            }
            else if let spend = info?.spend { 
                balance = "\(fmt(spend)) spent" 
                balanceColor = accentUncapped
            }
            else { balance = "—" }
        }

        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.view = AccountMenuItemView(name: account.name, balance: balance, balanceColor: balanceColor, dotImage: statusDot(for: st))
        head.isEnabled = true
                // Detail submenu.
        let detail = NSMenu()
        detail.autoenablesItems = false
        detail.minimumWidth = 280
        
        // Add detail title
        let detailTitle = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let detailTitleAttr = NSAttributedString(string: "\(account.name.uppercased()) DETAILS", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.5
        ])
        detailTitle.view = InfoMenuItemView(leftAttr: detailTitleAttr, height: 26)
        detailTitle.isEnabled = true
        detail.addItem(detailTitle)
        
        if case .error(let m) = st {
            let item = NSMenuItem(title: "Error: \(m)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            detail.addItem(item)
        } else {
            addDetail(detail, "Remaining:", fmt(remaining(for: info)), valueColor: .white, valueBold: true)
            addDetail(detail, "Spent:",     fmt(info?.spend))
            addDetail(detail, "Budget:",    info?.maxBudget == nil ? "unlimited" : fmt(info?.maxBudget))
            if let max = info?.maxBudget, let spend = info?.spend, max > 0 {
                let pct = spend / max * 100
                addDetail(detail, "Used:", String(format: "%.1f%%", pct), valueColor: pct > 80 ? accentWarn : .labelColor, valueBold: pct > 80)
            }
            addDetail(detail, "Key Alias:", info?.keyAlias ?? "—", isMono: true)
        }
        detail.addItem(.separator())
        let editItem = NSMenuItem(title: "Edit Settings…", action: #selector(onEdit), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = account.id
        editItem.image = symbolImage("pencil", description: "Edit account")
        detail.addItem(editItem)
        
        let removeItem = NSMenuItem(title: "Remove Account", action: #selector(onRemove), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = account.id
        removeItem.image = symbolImage("trash", description: "Remove account", color: accentDanger)
        let removeAttr = NSAttributedString(string: "Remove Account", attributes: [.foregroundColor: accentDanger])
        removeItem.attributedTitle = removeAttr
        detail.addItem(removeItem)
 
        head.submenu = detail
        return head
    }
 
    private func addDetail(_ menu: NSMenu, _ label: String, _ value: String, valueColor: NSColor = .secondaryLabelColor, valueBold: Bool = false, isMono: Bool = false) {
        let leftAttr = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        
        let valFont = isMono ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) 
                             : NSFont.systemFont(ofSize: 13, weight: valueBold ? .semibold : .regular)
        let rightAttr = NSAttributedString(string: value, attributes: [
            .font: valFont,
            .foregroundColor: valueColor
        ])
        
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = InfoMenuItemView(leftAttr: leftAttr, rightAttr: rightAttr, rightInset: 10, topInset: 5, bottomInset: 5, height: 25)
        item.isEnabled = true
        menu.addItem(item)
    }

    private func renderStatusTitle() {
        if settings.accounts.isEmpty {
            statusItem.button?.title = ""
            statusItem.button?.image = symbolImage("key.fill", description: "Arise Credit")
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
            statusItem.button?.image = nil
            statusItem.button?.title = fmt(totalRem) + (errors > 0 ? " ⚠️" : "")
        } else if errors > 0 {
            statusItem.button?.title = ""
            statusItem.button?.image = symbolImage("exclamationmark.triangle.fill", description: "Account error")
        } else {
            statusItem.button?.title = ""
            statusItem.button?.image = symbolImage("hourglass", description: "Loading")
        }
    }

    // MARK: - Pulse animation for "Updated" text
    func menuWillOpen(_ menu: NSMenu) {
        pulseAlpha = 1.0
        pulseDirection = -1
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.animatePulse()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func animatePulse() {
        pulseAlpha += pulseDirection * 0.025
        if pulseAlpha <= 0.35 { pulseAlpha = 0.35; pulseDirection = 1 }
        if pulseAlpha >= 1.0  { pulseAlpha = 1.0;  pulseDirection = -1 }

        let updatedStr = getUpdatedTimeText()
        headerTimeText = updatedStr

        guard let item = headerValueItem, let view = item.view as? InfoMenuItemView else { return }
        
        let rightAttr = NSAttributedString(string: updatedStr, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(pulseAlpha)
        ])
        view.updateRightString(rightAttr)
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
    private var didComplete = false

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
        complete(result, closeWindow: true)
    }

    func windowWillClose(_ notification: Notification) {
        complete(nil, closeWindow: false)
    }

    private func complete(_ result: Result?, closeWindow: Bool) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
        window.sheetParent?.endSheet(window)
        objc_setAssociatedObject(window, &AccountEditor.assocKey, nil, .OBJC_ASSOCIATION_RETAIN)
        if closeWindow {
            window.delegate = nil
            window.close()
        }
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

// MARK: - Custom non-selectable, non-dimmed Info Menu Item View
final class InfoMenuItemView: NSView {
    private let leftField = NSTextField()
    private let rightField = NSTextField()
    private let leftInset: CGFloat
    private let rightInset: CGFloat
    
    init(leftAttr: NSAttributedString, rightAttr: NSAttributedString = NSAttributedString(), leftInset: CGFloat = 20, rightInset: CGFloat = 20, topInset: CGFloat = 4, bottomInset: CGFloat = 4, height: CGFloat = 22) {
        self.leftInset = leftInset
        self.rightInset = rightInset
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: height))
        
        for f in [leftField, rightField] {
            f.isEditable = false
            f.isSelectable = false
            f.isBordered = false
            f.drawsBackground = false
            f.translatesAutoresizingMaskIntoConstraints = false
            addSubview(f)
        }
        
        leftField.alignment = .left
        rightField.alignment = .right
        
        leftField.attributedStringValue = leftAttr
        rightField.attributedStringValue = rightAttr
        
        // Prevent overlapping: rightField has compression resistance
        rightField.setContentCompressionResistancePriority(.required, for: .horizontal)
        leftField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        NSLayoutConstraint.activate([
            leftField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leftInset),
            leftField.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            leftField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            
            rightField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -rightInset),
            rightField.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            rightField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            
            leftField.trailingAnchor.constraint(lessThanOrEqualTo: rightField.leadingAnchor, constant: -8)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateRightString(_ attr: NSAttributedString) {
        rightField.attributedStringValue = attr
    }
}

// MARK: - Custom interactive, non-dimmed Account Menu Item View
final class AccountMenuItemView: NSView {
    private let statusDotView = NSImageView()
    private let nameField = NSTextField()
    private let balanceField = NSTextField()
    private let arrowView = NSImageView()
    
    private let name: String
    private let balance: String
    private let balanceColor: NSColor
    
    init(name: String, balance: String, balanceColor: NSColor, dotImage: NSImage?) {
        self.name = name
        self.balance = balance
        self.balanceColor = balanceColor
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        
        statusDotView.image = dotImage
        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDotView)
        
        for f in [nameField, balanceField] {
            f.isEditable = false
            f.isSelectable = false
            f.isBordered = false
            f.drawsBackground = false
            f.translatesAutoresizingMaskIntoConstraints = false
            addSubview(f)
        }
        
        nameField.alignment = .left
        balanceField.alignment = .right
        
        if #available(macOS 11.0, *) {
            arrowView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "")
        }
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrowView)
        
        NSLayoutConstraint.activate([
            statusDotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusDotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDotView.widthAnchor.constraint(equalToConstant: 10),
            statusDotView.heightAnchor.constraint(equalToConstant: 10),
            
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            
            arrowView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            arrowView.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowView.widthAnchor.constraint(equalToConstant: 8),
            arrowView.heightAnchor.constraint(equalToConstant: 12),
            
            balanceField.trailingAnchor.constraint(equalTo: arrowView.leadingAnchor, constant: -4),
            balanceField.centerYAnchor.constraint(equalTo: centerYAnchor),
            balanceField.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 8)
        ])
        
        updateColors()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func updateColors() {
        let isHi = enclosingMenuItem?.isHighlighted ?? false
        
        nameField.attributedStringValue = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isHi ? NSColor.white : NSColor.white
        ])
        
        balanceField.attributedStringValue = NSAttributedString(string: balance, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isHi ? NSColor.white : balanceColor
        ])
        
        if #available(macOS 10.14, *) {
            arrowView.contentTintColor = NSColor.white
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let menuItem = enclosingMenuItem, menuItem.isHighlighted {
            if #available(macOS 10.14, *) {
                NSColor.selectedContentBackgroundColor.set()
            } else {
                NSColor.selectedMenuItemColor.set()
            }
            bounds.fill()
        }
        updateColors()
    }
}

// MARK: - Custom interactive Action Menu Item View (with bright white shortcut)
final class ActionMenuItemView: NSView {
    private let iconView = NSImageView()
    private let nameField = NSTextField()
    private let shortcutField = NSTextField()
    
    private let name: String
    private let shortcut: String
    
    init(name: String, shortcut: String, icon: NSImage?) {
        self.name = name
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        
        iconView.image = icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        
        for f in [nameField, shortcutField] {
            f.isEditable = false
            f.isSelectable = false
            f.isBordered = false
            f.drawsBackground = false
            f.translatesAutoresizingMaskIntoConstraints = false
            addSubview(f)
        }
        
        nameField.alignment = .left
        shortcutField.alignment = .right
        
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            
            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcutField.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutField.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 8)
        ])
        
        updateColors()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func updateColors() {
        let isHi = enclosingMenuItem?.isHighlighted ?? false
        
        nameField.attributedStringValue = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: isHi ? NSColor.white : NSColor.white
        ])
        
        shortcutField.attributedStringValue = NSAttributedString(string: shortcut, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: isHi ? NSColor.white : NSColor.white
        ])
        
        if #available(macOS 10.14, *) {
            iconView.contentTintColor = isHi ? NSColor.white : NSColor.labelColor
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let menuItem = enclosingMenuItem, menuItem.isHighlighted {
            if #available(macOS 10.14, *) {
                NSColor.selectedContentBackgroundColor.set()
            } else {
                NSColor.selectedMenuItemColor.set()
            }
            bounds.fill()
        }
        updateColors()
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let menuItem = enclosingMenuItem, let menu = menuItem.menu else { return }
        menu.cancelTracking()
        if let action = menuItem.action {
            NSApp.sendAction(action, to: menuItem.target, from: menuItem)
        }
    }
}
