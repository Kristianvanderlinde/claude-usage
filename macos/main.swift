// Claude Usage — menubalk-app die je Claude-plangebruik en Claude Code-tokens toont.
//
// Bronnen:
//  - Plan-limieten: GET https://api.anthropic.com/api/oauth/usage met het OAuth-token
//    dat Claude Code in de Keychain bewaart ("Claude Code-credentials"). Het token wordt
//    alleen gelezen, nooit ververst — dat blijft Claude Code zelf doen.
//  - Tokens: de lokale transcripts in ~/.claude/projects/**/*.jsonl.
//
// Meerdere accounts: elke Claude-configmap (CLAUDE_CONFIG_DIR) is een account met een eigen
// login, eigen Keychain-item en eigen transcripts. Zie `Account.discover()`.

import AppKit
import Combine
import CryptoKit
import SwiftUI

// MARK: - Accounts

/// Wat Claude Code over de login weet, uit .claude.json.
struct AccountInfo {
    var email: String?
    var organization: String?
    var organizationType: String?   // bv. "claude_team" of "claude_pro"
}

struct Account {
    let configDir: URL
    var name: String
    let defaultName: String
    var color: NSColor
    var hidden = false
    var manual = false      // zelf toegevoegd in de instellingen, kan ook weer weg

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let defaultDir = home.appendingPathComponent(".claude")
    static let palette = ["#D97857", "#2F6FD0", "#8E44AD", "#2E9E5B", "#E08A1E", "#D6457A", "#1A9AA0", "#7A7A7A"]

    /// Sleutel voor instellingen en opgeslagen waarden, bv. "~/.claude-prive".
    var key: String { Self.key(for: configDir) }
    static func key(for dir: URL) -> String {
        let p = dir.path, h = home.path
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }

    /// ~/.claude is wat Claude Code zonder CLAUDE_CONFIG_DIR gebruikt.
    var isDefault: Bool { configDir.path == Self.defaultDir.path }

    /// Claude Code zet achter het Keychain-item de eerste 8 tekens van sha256(configmap)
    /// als CLAUDE_CONFIG_DIR is gezet.
    var keychainService: String { Self.keychainService(for: configDir) }

    static func keychainService(for dir: URL) -> String {
        if dir.path == defaultDir.path { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(dir.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }

    var projectDirs: [URL] {
        var dirs = [configDir.appendingPathComponent("projects")]
        if isDefault { dirs.append(Self.home.appendingPathComponent(".config/claude/projects")) }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Prefix voor opgeslagen waarden; het standaardaccount houdt de sleutels van vroeger.
    var storePrefix: String { isDefault ? "" : "\(key)." }

    func info() -> AccountInfo { Self.info(for: configDir) }

    /// Bij ~/.claude staat .claude.json in de thuismap, anders in de configmap zelf.
    static func info(for dir: URL) -> AccountInfo {
        let file = dir.path == defaultDir.path ? home.appendingPathComponent(".claude.json")
                                               : dir.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["oauthAccount"] as? [String: Any] else { return AccountInfo() }
        return AccountInfo(email: oauth["emailAddress"] as? String,
                           organization: oauth["organizationName"] as? String,
                           organizationType: oauth["organizationType"] as? String)
    }

    /// Naam zonder instellen: de organisatie bij Team of Enterprise, anders "Persoonlijk".
    /// Zonder login valt hij terug op de mapnaam.
    static func defaultName(for dir: URL, info: AccountInfo) -> String {
        if let type = info.organizationType {
            if type.contains("team") || type.contains("enterprise"),
               let org = info.organization, !org.isEmpty { return org }
            return "Persoonlijk"
        }
        let id = dir.lastPathComponent
        if id == ".claude" { return "Claude" }
        return String(id.drop { $0 == "." }).replacingOccurrences(of: "claude-", with: "").capitalized
    }

    /// Lijkt de map op een Claude-configmap? Dan is er een login of zijn er transcripts.
    static func looksLikeConfigDir(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return hasKeychainItem(keychainService(for: dir))
            || fm.fileExists(atPath: dir.appendingPathComponent("projects").path)
            || fm.fileExists(atPath: dir.appendingPathComponent(".claude.json").path)
    }

    /// ~/.claude, CLAUDE_CONFIG_DIR, elke map ~/.claude-* met een login in de Keychain en de
    /// mappen die je zelf hebt toegevoegd. Namen, kleuren en volgorde komen uit `AccountSettings`.
    static func discover() -> [Account] {
        var dirs: [(URL, manual: Bool)] = [(defaultDir, false)]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs.append((URL(fileURLWithPath: env).standardizedFileURL, false))
        }
        let others = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        for dir in others.sorted(by: { $0.path < $1.path }) where dir.lastPathComponent.hasPrefix(".claude-") {
            let dir = dir.standardizedFileURL
            if hasKeychainItem(keychainService(for: dir)) { dirs.append((dir, false)) }
        }
        for path in AccountSettings.manualDirs {
            dirs.append((URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL, true))
        }

        var seen = Set<String>()
        let unique = dirs.filter { seen.insert($0.0.path).inserted }
        let infos = unique.map { info(for: $0.0) }
        var defaults = zip(unique, infos).map { defaultName(for: $0.0.0, info: $0.1) }
        // Twee keer "Persoonlijk"? Dan het deel van het e-mailadres vóór de @.
        for (i, name) in defaults.enumerated() where defaults.filter({ $0 == name }).count > 1 {
            if let local = infos[i].email?.split(separator: "@").first { defaults[i] = String(local) }
        }

        let prefs = AccountSettings.prefs
        let accounts = unique.enumerated().map { i, entry -> Account in
            let (dir, manual) = entry
            let p = prefs[key(for: dir)] ?? [:]
            let name = (p["name"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? defaults[i]
            let color = (p["color"] as? String).flatMap(NSColor.init(hex:))
                ?? NSColor(hex: palette[i % palette.count])!
            return Account(configDir: dir, name: name, defaultName: defaults[i], color: color,
                           hidden: p["hidden"] as? Bool ?? false, manual: manual)
        }
        let order = AccountSettings.order
        return accounts.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.key) ?? order.count + a.offset
            let ib = order.firstIndex(of: b.element.key) ?? order.count + b.offset
            return ia < ib
        }.map(\.element)
    }

    /// Bestaat het Keychain-item? Leest alleen de kenmerken, niet het wachtwoord.
    static func hasKeychainItem(_ service: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Wat je per account instelt, bewaard in UserDefaults. Sleutels zijn `Account.key`.
enum AccountSettings {
    private static let store = UserDefaults.standard

    /// Per account: "name", "color" (hex) en "hidden".
    static var prefs: [String: [String: Any]] {
        get { store.dictionary(forKey: "accountPrefs") as? [String: [String: Any]] ?? [:] }
        set { store.set(newValue, forKey: "accountPrefs") }
    }
    static var order: [String] {
        get { store.stringArray(forKey: "accountOrder") ?? [] }
        set { store.set(newValue, forKey: "accountOrder") }
    }
    /// Zelf toegevoegde configmappen.
    static var manualDirs: [String] {
        get { store.stringArray(forKey: "accountDirs") ?? [] }
        set { store.set(newValue, forKey: "accountDirs") }
    }

    static func update(_ key: String, _ change: (inout [String: Any]) -> Void) {
        var all = prefs
        var entry = all[key] ?? [:]
        change(&entry)
        all[key] = entry.isEmpty ? nil : entry
        prefs = all
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

// MARK: - Modellen

struct LimitInfo {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

struct TokenTotals {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var total: Int { input + output + cacheWrite + cacheRead }
    mutating func add(_ o: TokenTotals) {
        input += o.input; output += o.output; cacheWrite += o.cacheWrite; cacheRead += o.cacheRead
    }
}

struct TokenStats {
    var today = TokenTotals()
    var week = TokenTotals()
    var todayByModel: [String: TokenTotals] = [:]
}

/// Uitkomst van één keer ophalen bij de usage-API.
enum FetchResult {
    case ok([LimitInfo], Data)
    case rateLimited
    case failed(String)
}

enum PlanState {
    case loading
    case ok([LimitInfo])
    case error(String)
}

// MARK: - Plan-limieten

enum PlanFetcher {
    /// Token en abonnementstype (bv. "team" of "max") uit de Claude Code-login.
    static func readLogin(service: String) -> (token: String, subscription: String?)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return (token, oauth["subscriptionType"] as? String)
    }

    static func fetch(token: String?, completion: @escaping (FetchResult) -> Void) {
        guard let token = token else {
            completion(.failed("Geen Claude Code-login gevonden in de Keychain"))
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failed("Netwerkfout: \(err.localizedDescription)")); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: break
            case 401: completion(.failed("Login verlopen — open Claude Code om te verversen")); return
            case 429: completion(.rateLimited); return
            default: completion(.failed("Onverwachte status \(code)")); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failed("Antwoord niet te lezen")); return
            }
            completion(.ok(parse(json), data))
        }.resume()
    }

    static func parse(_ json: [String: Any]) -> [LimitInfo] {
        // Nieuwere responses hebben een generieke `limits`-lijst; anders five_hour/seven_day.
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            return limits.compactMap { l in
                guard let pct = (l["percent"] as? NSNumber)?.doubleValue else { return nil }
                let kind = l["kind"] as? String ?? "?"
                let scope = l["scope"] as? String
                return LimitInfo(label: label(kind: kind, scope: scope), percent: pct,
                                 resetsAt: date(l["resets_at"]))
            }
        }
        var out: [LimitInfo] = []
        for (key, label) in [("five_hour", "Sessie (5 uur)"), ("seven_day", "Week"),
                             ("seven_day_opus", "Week · Opus"), ("seven_day_sonnet", "Week · Sonnet")] {
            if let o = json[key] as? [String: Any], let u = (o["utilization"] as? NSNumber)?.doubleValue {
                out.append(LimitInfo(label: label, percent: u, resetsAt: date(o["resets_at"])))
            }
        }
        return out
    }

    static func label(kind: String, scope: String?) -> String {
        let base: String
        switch kind {
        case "session": base = "Sessie (5 uur)"
        case "weekly_all": base = "Week"
        default: base = kind.hasPrefix("weekly") ? "Week" : kind.capitalized
        }
        if let scope = scope, !scope.isEmpty { return "\(base) · \(scope.capitalized)" }
        if kind.hasPrefix("weekly_"), kind != "weekly_all" {
            return "\(base) · \(kind.dropFirst("weekly_".count).capitalized)"
        }
        return base
    }

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Claude Code-tokens uit lokale logs

enum TokenScanner {
    static func scan(_ projectDirs: [URL]) -> TokenStats {
        let cal = Calendar.current
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        let startWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startToday

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Eén bericht kan meerdere regels opleveren (streaming); de laatste wint.
        var perMessage: [String: (Date, String, TokenTotals)] = [:]

        for dir in projectDirs {
            guard let en = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if mod < startWeek { continue }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                content.enumerateLines { line, _ in
                    guard line.contains("\"usage\""),
                          let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let msg = obj["message"] as? [String: Any],
                          let usage = msg["usage"] as? [String: Any],
                          let ts = obj["timestamp"] as? String,
                          let when = iso.date(from: ts), when >= startWeek else { return }
                    let model = msg["model"] as? String ?? "onbekend"
                    if model == "<synthetic>" { return }
                    func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
                    let t = TokenTotals(input: n("input_tokens"), output: n("output_tokens"),
                                        cacheWrite: n("cache_creation_input_tokens"),
                                        cacheRead: n("cache_read_input_tokens"))
                    let key = "\(msg["id"] as? String ?? UUID().uuidString):\(obj["requestId"] as? String ?? "")"
                    perMessage[key] = (when, model, t)
                }
            }
        }

        var stats = TokenStats()
        for (when, model, t) in perMessage.values {
            stats.week.add(t)
            if when >= startToday {
                stats.today.add(t)
                stats.todayByModel[model, default: TokenTotals()].add(t)
            }
        }
        return stats
    }
}

// MARK: - Opmaak

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.1f mld", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.0fK", d / 1_000) }
        return "\(n)"
    }

    static func resetTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE d MMM HH:mm"
        return f.string(from: d)
    }

    static func remaining(_ d: Date, now: Date = Date()) -> String {
        let left = d.timeIntervalSince(now)
        guard left > 0 else { return "nu" }
        let h = Int(left) / 3600, m = (Int(left) % 3600) / 60
        if h >= 24 { return "over \(h / 24)d \(h % 24)u" }
        return h > 0 ? "over \(h)u \(m)m" : "over \(m)m"
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "")
    }
}

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static func level(_ pct: Double) -> Color {
        pct >= 90 ? .red : pct >= 75 ? .orange : .claude
    }
}

extension NSColor {
    static func level(_ pct: Double) -> NSColor {
        pct >= 90 ? .systemRed : pct >= 75 ? .systemOrange : .labelColor
    }
}

// MARK: - Start bij inloggen

/// Beheert dezelfde LaunchAgent die `build.sh --login` aanmaakt.
enum LoginItem {
    static let label = "nl.broekhuis.claude-usage"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Alleen beschikbaar als de app als .app-bundel draait.
    static var available: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(_ enabled: Bool) throws {
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } else if isEnabled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}

// MARK: - Model

/// Alle accounts, het gekozen tabblad en de instellingen die voor de hele app gelden.
final class AppModel: ObservableObject {
    /// Alle gevonden accounts in de gekozen volgorde, ook de verborgen.
    @Published private(set) var all: [UsageModel] = []
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedAccount") }
    }
    private var bag = Set<AnyCancellable>()
    private var started = false

    init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedAccount") ?? ""
        reload()
    }

    /// De zichtbare accounts: één tabblad per account.
    var accounts: [UsageModel] { all.filter { !$0.account.hidden } }
    var selected: UsageModel { accounts.first { $0.account.key == selectedID } ?? accounts.first ?? all[0] }
    var multiple: Bool { accounts.count > 1 }

    /// Accounts opnieuw zoeken. Bestaande accounts houden hun cijfers.
    func reload() {
        let old = Dictionary(all.map { ($0.account.key, $0) }, uniquingKeysWith: { a, _ in a })
        all = Account.discover().map { account in
            if let m = old[account.key] { m.account = account; return m }
            let m = UsageModel(account: account)
            // Wijzigingen in een account doorgeven, zodat paneel en menubalk meebewegen.
            m.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
            if started && !account.hidden { m.refresh(force: false) }
            return m
        }
        if !accounts.contains(where: { $0.account.key == selectedID }) {
            selectedID = (accounts.first ?? all[0]).account.key
        }
    }

    /// De verversknop dwingt alleen het gekozen account; de rest volgt het eigen schema,
    /// zodat één klik niet bij elk account een API-verzoek doet.
    func refresh(force: Bool) {
        started = true
        for m in accounts { m.refresh(force: force && m === selected) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do { try LoginItem.set(enabled) } catch { NSSound.beep() }
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: Instellingen per account

    func customName(_ m: UsageModel) -> String {
        AccountSettings.prefs[m.account.key]?["name"] as? String ?? ""
    }

    /// Een lege naam zet de standaardnaam terug.
    func setName(_ m: UsageModel, _ name: String) {
        AccountSettings.update(m.account.key) { $0["name"] = name.isEmpty ? nil : name }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        m.account.name = trimmed.isEmpty ? m.account.defaultName : trimmed
    }

    func setColor(_ m: UsageModel, _ color: NSColor) {
        AccountSettings.update(m.account.key) { $0["color"] = color.hex }
        m.account.color = color
    }

    /// Er blijft altijd minstens één account zichtbaar.
    func setHidden(_ m: UsageModel, _ hidden: Bool) {
        guard !hidden || accounts.count > 1 else { NSSound.beep(); return }
        AccountSettings.update(m.account.key) { $0["hidden"] = hidden ? true : nil }
        m.account.hidden = hidden
        if hidden, selectedID == m.account.key, let next = accounts.first { selectedID = next.account.key }
        if !hidden { m.refresh(force: false) }
    }

    func move(_ m: UsageModel, by offset: Int) {
        guard let i = all.firstIndex(where: { $0 === m }), all.indices.contains(i + offset) else { return }
        all.swapAt(i, i + offset)
        AccountSettings.order = all.map(\.account.key)
    }

    /// Geeft een melding terug als de map niet kan.
    func addFolder(_ url: URL) -> String? {
        let dir = url.standardizedFileURL
        let key = Account.key(for: dir)
        if all.contains(where: { $0.account.key == key }) { return "\(key) staat er al tussen." }
        guard Account.looksLikeConfigDir(dir) else {
            return "Geen Claude Code-login of transcripts gevonden in \(key)."
        }
        AccountSettings.manualDirs.append(key)
        reload()
        return nil
    }

    func remove(_ m: UsageModel) {
        let key = m.account.key
        AccountSettings.manualDirs.removeAll { $0 == key }
        AccountSettings.update(key) { $0 = [:] }
        AccountSettings.order.removeAll { $0 == key }
        reload()
    }
}

final class UsageModel: ObservableObject {
    @Published var account: Account
    @Published var plan: PlanState = .loading
    @Published var planWarning: String?
    @Published var tokens: TokenStats?
    @Published var lastUpdate: Date?
    @Published var refreshing = false
    @Published var subscription: String?
    @Published var email: String?

    @Published var planFetchedAt: Date?

    private var pending = 0
    private(set) var nextPlanFetch = Date.distantPast
    private(set) var rateLimitStrikes = 0
    private let store = UserDefaults.standard

    static let planInterval: TimeInterval = 600              // usage-API elke 10 min
    static let backoff: [TimeInterval] = [900, 1800, 3600]   // na een 429: 15, 30, 60 min

    init(account: Account) {
        self.account = account
        restore()
    }

    private func key(_ name: String) -> String { account.storePrefix + name }

    /// Tokens worden altijd opnieuw geteld; de usage-API alleen als het tijd is,
    /// of bij `force` (de verversknop).
    func refresh(force: Bool) {
        refreshing = true
        if force || Date() >= nextPlanFetch { fetchPlan() }
        pending += 1
        let dirs = account.projectDirs
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = TokenScanner.scan(dirs)
            DispatchQueue.main.async {
                self?.tokens = stats
                self?.done()
            }
        }
    }

    private func fetchPlan() {
        nextPlanFetch = Date().addingTimeInterval(Self.planInterval)   // geen dubbele aanvragen
        pending += 1
        let account = account
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let login = PlanFetcher.readLogin(service: account.keychainService)
            let email = account.info().email
            PlanFetcher.fetch(token: login?.token) { result in
                DispatchQueue.main.async {
                    self?.subscription = login?.subscription ?? self?.subscription
                    self?.email = email ?? self?.email
                    self?.apply(result)
                    self?.done()
                }
            }
        }
    }

    func apply(_ result: FetchResult) {
        switch result {
        case .ok(let limits, let raw):
            plan = .ok(limits)
            planWarning = nil
            planFetchedAt = Date()
            rateLimitStrikes = 0
            nextPlanFetch = Date().addingTimeInterval(Self.planInterval)
            store.set(raw, forKey: key("lastUsage"))
            store.set(planFetchedAt, forKey: key("lastUsageAt"))
            store.set(subscription, forKey: key("subscription"))
            store.set(email, forKey: key("email"))
        case .rateLimited:
            let wait = Self.backoff[min(rateLimitStrikes, Self.backoff.count - 1)]
            rateLimitStrikes += 1
            nextPlanFetch = Date().addingTimeInterval(wait)
            showProblem(Self.blockedMessage(until: nextPlanFetch))
        case .failed(let msg):
            nextPlanFetch = Date().addingTimeInterval(Self.planInterval)
            showProblem(msg)
        }
        store.set(nextPlanFetch, forKey: key("nextPlanFetch"))
        store.set(rateLimitStrikes, forKey: key("rateLimitStrikes"))
    }

    static func blockedMessage(until: Date) -> String {
        "Tijdelijk geblokkeerd (te veel verzoeken), opnieuw om \(Fmt.time(until))"
    }

    /// Zijn er al cijfers, dan blijven die staan en komt de melding eronder.
    private func showProblem(_ msg: String) {
        if case .ok = plan { planWarning = msg } else { plan = .error(msg) }
    }

    /// Laatste cijfers en wachttijd van een vorige keer terugzetten, zodat een herstart
    /// niet meteen een nieuw verzoek doet.
    private func restore() {
        subscription = store.string(forKey: key("subscription"))
        email = store.string(forKey: key("email"))
        if let raw = store.data(forKey: key("lastUsage")),
           let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            plan = .ok(PlanFetcher.parse(json))
            planFetchedAt = store.object(forKey: key("lastUsageAt")) as? Date
        }
        rateLimitStrikes = store.integer(forKey: key("rateLimitStrikes"))
        var next = store.object(forKey: key("nextPlanFetch")) as? Date ?? .distantPast
        if let at = planFetchedAt { next = max(next, at.addingTimeInterval(Self.planInterval)) }
        nextPlanFetch = next
        if rateLimitStrikes > 0, next > Date() { showProblem(Self.blockedMessage(until: next)) }
    }

    private func done() {
        pending -= 1
        lastUpdate = Date()
        if pending <= 0 { pending = 0; refreshing = false }
    }

    var headline: [LimitInfo] {
        guard case .ok(let limits) = plan else { return [] }
        let parts = [limits.first { $0.label.hasPrefix("Sessie") }, limits.first { $0.label == "Week" }].compactMap { $0 }
        return parts.isEmpty ? Array(limits.prefix(1)) : parts
    }
}

// MARK: - Paneel

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

struct SectionTitle: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct LimitRow: View {
    let limit: LimitInfo
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.level(limit.percent))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.level(limit.percent))
                        .frame(width: max(limit.percent > 0 ? 6 : 0, geo.size.width * min(limit.percent, 100) / 100))
                }
            }
            .frame(height: 6)
            if let r = limit.resetsAt {
                Text("Reset \(Fmt.resetTime(r)) · \(Fmt.remaining(r, now: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gekleurd vierkantje met de eerste letter van het account, zoals in de menubalk.
struct AccountBadge: View {
    let account: Account
    var size: CGFloat = 16
    var body: some View {
        Text(String(account.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Color(nsColor: account.color)))
    }
}

struct AccountTabs: View {
    @ObservedObject var app: AppModel
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(app.accounts.enumerated()), id: \.offset) { i, m in
                let selected = m === app.selected
                Button { app.selectedID = m.account.key } label: {
                    HStack(spacing: 6) {
                        AccountBadge(account: m.account, size: 15)
                        Text(m.account.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .lineLimit(1).truncationMode(.tail)
                        if let session = m.headline.first {
                            Text("\(Int(session.percent.rounded()))%")
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .foregroundStyle(Color.level(session.percent).opacity(selected ? 1 : 0.8))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Color(nsColor: m.account.color).opacity(0.18) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color(nsColor: m.account.color).opacity(0.6) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .help("\(m.account.name) (⌘\(i + 1))")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }
}

struct UsagePanel: View {
    @ObservedObject var app: AppModel
    var onSettings: () -> Void
    var onQuit: () -> Void

    private var model: UsageModel { app.selected }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 14) {
                if app.multiple { AccountTabs(app: app) }
                header
                planSection(now: ctx.date)
                tokenSection
                if let u = model.lastUpdate {
                    Text("Bijgewerkt \(Fmt.time(u))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, -6)
                }
                Divider()
                footer
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
            // Het e-mailadres is de titel: de accountnaam staat al in het tabblad.
            VStack(alignment: .leading, spacing: 1) {
                Text(model.email ?? "Claude-gebruik")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.email ?? "")
                    .contextMenu {
                        if let email = model.email {
                            Button("Kopieer e-mailadres") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(email, forType: .string)
                            }
                        }
                    }
                let details = [model.subscription.map { "\($0.capitalized)-abonnement" },
                               app.multiple ? model.account.name : nil].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func planSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Planlimieten", icon: "gauge.with.dots.needle.33percent")
                Spacer()
                if let at = model.planFetchedAt {
                    Text("stand van \(Fmt.resetTime(at))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Card {
                switch model.plan {
                case .loading:
                    HStack { ProgressView().controlSize(.small); Text("Laden…").foregroundStyle(.secondary) }
                case .error(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                case .ok(let limits):
                    VStack(alignment: .leading, spacing: 14) {
                        if limits.isEmpty { Text("Geen limieten gemeld").foregroundStyle(.secondary) }
                        ForEach(Array(limits.enumerated()), id: \.offset) { _, l in
                            LimitRow(limit: l, now: now)
                        }
                        if let w = model.planWarning {
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Claude Code-tokens", icon: "terminal")
            Card {
                if let t = model.tokens {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Vandaag").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(Fmt.tokens(t.today.total))
                                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        HStack {
                            Stat(label: "Invoer", value: Fmt.tokens(t.today.input))
                            Stat(label: "Uitvoer", value: Fmt.tokens(t.today.output))
                            Stat(label: "Cache", value: Fmt.tokens(t.today.cacheWrite + t.today.cacheRead))
                        }
                        if !t.todayByModel.isEmpty {
                            Divider()
                            ForEach(t.todayByModel.sorted { $0.value.total > $1.value.total }, id: \.key) { m, mt in
                                HStack {
                                    Circle().fill(Color.claude).frame(width: 6, height: 6)
                                    Text(Fmt.shortModel(m)).font(.system(size: 12))
                                    Spacer()
                                    Text(Fmt.tokens(mt.total)).font(.system(size: 12)).monospacedDigit()
                                }
                            }
                        }
                        Divider()
                        HStack {
                            Text("Deze week").font(.system(size: 12))
                            Spacer()
                            Text(Fmt.tokens(t.week.total)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Laden…").foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if LoginItem.available {
                Toggle("Start bij inloggen", isOn: Binding(
                    get: { app.launchAtLogin },
                    set: { app.setLaunchAtLogin($0) }))
                    .toggleStyle(CheckToggleStyle())
                    .padding(.leading, -6)
                    .help("Open Claude Usage automatisch als je inlogt")
            }
            Spacer()
            iconButton("arrow.clockwise", help: "Nu verversen (⌘R)") { app.refresh(force: true) }
                .keyboardShortcut("r")
                .disabled(model.refreshing)
            iconButton("safari", help: "Open gebruik op claude.ai") {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            }
            iconButton("gearshape", help: "Accounts instellen (⌘,)", action: onSettings)
                .keyboardShortcut(",")
            iconButton("power", help: "Stop Claude Usage (⌘Q)", action: onQuit)
                .keyboardShortcut("q")
        }
    }
}

func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium))
    }
    .buttonStyle(IconButtonStyle())
    .help(help)
}

// MARK: - Instellingen

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Accounts", icon: "person.2")
            VStack(spacing: 8) {
                ForEach(Array(app.all.enumerated()), id: \.element.account.key) { i, m in
                    AccountSettingsRow(app: app, model: m, isFirst: i == 0, isLast: i == app.all.count - 1)
                }
            }
            HStack {
                Button("Map toevoegen…", action: addFolder)
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Text("De app vindt ~/.claude en elke map ~/.claude-* met een Claude Code-login vanzelf. "
                 + "Gebruik je CLAUDE_CONFIG_DIR met een andere map, voeg die dan hier toe. "
                 + "Laat je de naam leeg, dan gebruikt de app de organisatie of \"Persoonlijk\".")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 500)
    }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.showsHiddenFiles = true
        p.directoryURL = Account.home
        p.prompt = "Toevoegen"
        p.message = "Kies de configmap van een Claude Code-account (wat je als CLAUDE_CONFIG_DIR gebruikt)."
        if p.runModal() == .OK, let url = p.url { message = app.addFolder(url) }
    }
}

struct AccountSettingsRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: UsageModel
    let isFirst: Bool
    let isLast: Bool
    @State private var pickingColor = false

    var body: some View {
        let a = model.account
        Card {
            HStack(spacing: 10) {
                Button { pickingColor = true } label: { AccountBadge(account: a, size: 26) }
                    .buttonStyle(.plain)
                    .help("Kleur kiezen")
                    .popover(isPresented: $pickingColor, arrowEdge: .bottom) {
                        ColorChoice(current: a.color) { app.setColor(model, $0) }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    TextField(a.defaultName, text: Binding(get: { app.customName(model) },
                                                           set: { app.setName(model, $0) }))
                        .textFieldStyle(.roundedBorder)
                    Text([model.email, a.key].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help([model.email, a.configDir.path].compactMap { $0 }.joined(separator: "\n"))
                }
                HStack(spacing: 0) {
                    iconButton("chevron.up", help: "Naar voren") { app.move(model, by: -1) }.disabled(isFirst)
                    iconButton("chevron.down", help: "Naar achteren") { app.move(model, by: 1) }.disabled(isLast)
                    iconButton(a.hidden ? "eye.slash" : "eye", help: a.hidden ? "Tonen" : "Verbergen") {
                        app.setHidden(model, !a.hidden)
                    }
                    if a.manual {
                        iconButton("trash", help: "Verwijderen uit de lijst") { app.remove(model) }
                    }
                }
            }
        }
        .opacity(a.hidden ? 0.55 : 1)
    }
}

struct ColorChoice: View {
    let current: NSColor
    let onPick: (NSColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Account.palette, id: \.self) { hex in
                    let color = NSColor(hex: hex)!
                    Button { onPick(color) } label: {
                        Circle().fill(Color(nsColor: color)).frame(width: 22, height: 22)
                            .overlay {
                                if current.hex == hex {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Andere kleur", selection: Binding(get: { Color(nsColor: current) },
                                                         set: { onPick(NSColor($0)) }),
                        supportsOpacity: false)
                .font(.system(size: 12))
        }
        .padding(12)
    }
}

/// Vinkje in dezelfde stijl als de icoonknoppen.
struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(configuration.isOn ? Color.claude : Color.secondary)
                configuration.label
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.8))
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(IconButtonStyle(fixedWidth: false))
    }
}

struct IconButtonStyle: ButtonStyle {
    var fixedWidth = true
    func makeBody(configuration: Configuration) -> some View { IconButton(configuration: configuration, fixedWidth: fixedWidth) }

    private struct IconButton: View {
        let configuration: Configuration
        let fixedWidth: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.5))
                .frame(width: fixedWidth ? 28 : nil, height: 28)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hover ? 0.08 : 0)))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

// MARK: - App

/// Randloos paneel dat toetsenbordinvoer mag krijgen (voor ⌘R / ⌘Q).
final class UsageWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let app = AppModel()
    private var panel: UsageWindow!
    private var hosting: NSHostingView<UsagePanel>!
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var outsideClickMonitor: Any?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildPanel()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
        }
        app.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.renderTitle()
                    if self?.panel.isVisible == true { self?.positionPanel() }
                }
            }
            .store(in: &bag)

        renderTitle()
        app.refresh(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.app.refresh(force: false)
        }
    }

    /// De app heeft geen zichtbare menubalk, maar zonder Wijzig-menu werken ⌘C/⌘V/⌘A
    /// niet in de tekstvelden van het instellingenvenster.
    private func buildMenu() {
        let main = NSMenu()
        let edit = NSMenu(title: "Wijzig")
        edit.addItem(withTitle: "Herstel", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Opnieuw", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Knip", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieer", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Plak", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecteer alles", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Venster")
        window.addItem(withTitle: "Sluit", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for menu in [edit, window] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func openSettings() {
        hidePanel()
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(app: app)))
            w.title = "Claude Usage — Accounts"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildPanel() {
        panel = UsageWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        hosting = NSHostingView(rootView: UsagePanel(app: app, onSettings: { [weak self] in self?.openSettings() },
                                                     onQuit: { NSApp.terminate(nil) }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                               queue: .main) { [weak self] _ in self?.hidePanel() }
    }

    /// Zet het paneel direct onder het menubalk-icoon en houd het binnen het zichtbare scherm.
    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor

        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY - 6, visible.maxY - 6)
        let height = min(size.height, top - visible.minY - 8)
        panel.setFrame(NSRect(x: x, y: top - height, width: size.width, height: height), display: true)
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel(); return }
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.hidePanel()
        }
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    /// Gekleurd vierkantje met de eerste letter van het account (zelfde als `AccountBadge`).
    private static func badge(for account: Account) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            account.color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let letter = String(account.name.prefix(1)).uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
            let ls = letter.size(withAttributes: attrs)
            letter.draw(at: NSPoint(x: rect.midX - ls.width / 2, y: rect.midY - ls.height / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let model = app.selected
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let s: NSMutableAttributedString
        if app.multiple {
            button.image = Self.badge(for: model.account)
            button.imagePosition = .imageLeading
            s = NSMutableAttributedString(string: " ", attributes: [.font: font])
        } else {
            button.image = nil
            s = NSMutableAttributedString(string: "✳︎ ", attributes: [.font: font])
        }
        let parts = model.headline
        switch model.plan {
        case .ok where !parts.isEmpty:
            for (i, l) in parts.enumerated() {
                if i > 0 { s.append(NSAttributedString(string: " · ", attributes: [.font: font])) }
                s.append(NSAttributedString(string: "\(Int(l.percent.rounded()))%",
                                            attributes: [.font: font, .foregroundColor: NSColor.level(l.percent)]))
            }
        case .error:
            s.append(NSAttributedString(string: "–", attributes: [.font: font]))
        default:
            s.append(NSAttributedString(string: "…", attributes: [.font: font]))
        }
        button.attributedTitle = s
        button.toolTip = app.multiple ? "Claude-gebruik (\(model.account.name)): sessie · week"
                                      : "Claude-gebruik: sessie · week"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
