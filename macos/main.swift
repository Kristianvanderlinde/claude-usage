// Claude Usage — menubalk-app die je Claude-plangebruik en Claude Code-tokens toont.
//
// Bronnen:
//  - Plan-limieten: GET https://api.anthropic.com/api/oauth/usage met het OAuth-token
//    dat Claude Code in de Keychain bewaart ("Claude Code-credentials"). Het token wordt
//    alleen gelezen, nooit ververst — dat blijft Claude Code zelf doen.
//  - Tokens: de lokale transcripts in ~/.claude/projects/**/*.jsonl.

import AppKit
import Combine
import SwiftUI

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

enum PlanState {
    case loading
    case ok([LimitInfo])
    case error(String)
}

// MARK: - Plan-limieten

enum PlanFetcher {
    /// Abonnementstype uit de Claude Code-login, bv. "team" of "max".
    static private(set) var subscription: String?

    static func readAccessToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
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
        subscription = oauth["subscriptionType"] as? String
        return token
    }

    static func fetch(completion: @escaping (PlanState) -> Void) {
        guard let token = readAccessToken() else {
            completion(.error("Geen Claude Code-login gevonden in de Keychain"))
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.error("Netwerkfout: \(err.localizedDescription)")); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: break
            case 401: completion(.error("Login verlopen — open Claude Code om te verversen")); return
            case 429: completion(.error("Even te vaak opgevraagd (429), probeer later")); return
            default: completion(.error("Onverwachte status \(code)")); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.error("Antwoord niet te lezen")); return
            }
            completion(.ok(parse(json)))
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
    static func projectDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".claude/projects"),
                    home.appendingPathComponent(".config/claude/projects")]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects"), at: 0)
        }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func scan() -> TokenStats {
        let cal = Calendar.current
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        let startWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startToday

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Eén bericht kan meerdere regels opleveren (streaming); de laatste wint.
        var perMessage: [String: (Date, String, TokenTotals)] = [:]

        for dir in projectDirs() {
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

final class UsageModel: ObservableObject {
    @Published var plan: PlanState = .loading
    @Published var planWarning: String?
    @Published var tokens: TokenStats?
    @Published var lastUpdate: Date?
    @Published var refreshing = false
    @Published var subscription: String?
    @Published var launchAtLogin = LoginItem.isEnabled

    func setLaunchAtLogin(_ enabled: Bool) {
        do { try LoginItem.set(enabled) } catch { NSSound.beep() }
        launchAtLogin = LoginItem.isEnabled
    }

    private var lastPlanFetch: Date?
    private var pending = 0
    let planInterval: TimeInterval = 180   // usage-API niet vaker dan elke 3 min

    func refresh(force: Bool) {
        let needPlan = force || lastPlanFetch.map { Date().timeIntervalSince($0) >= planInterval } ?? true
        refreshing = true
        if needPlan {
            lastPlanFetch = Date()
            pending += 1
            PlanFetcher.fetch { [weak self] state in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Bij een tijdelijke fout de laatste goede waarden laten staan.
                    if case .error(let msg) = state, case .ok = self.plan {
                        self.planWarning = msg
                    } else {
                        self.plan = state
                        self.planWarning = nil
                    }
                    self.subscription = PlanFetcher.subscription
                    self.done()
                }
            }
        }
        pending += 1
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = TokenScanner.scan()
            DispatchQueue.main.async {
                self?.tokens = stats
                self?.done()
            }
        }
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

struct UsagePanel: View {
    @ObservedObject var model: UsageModel
    var onQuit: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 14) {
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
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude-gebruik").font(.system(size: 15, weight: .semibold))
                if let sub = model.subscription {
                    Text("\(sub.capitalized)-abonnement").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func planSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Planlimieten", icon: "gauge.with.dots.needle.33percent")
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
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(CheckToggleStyle())
                    .padding(.leading, -6)
                    .help("Open Claude Usage automatisch als je inlogt")
            }
            Spacer()
            iconButton("arrow.clockwise", help: "Nu verversen (⌘R)") { model.refresh(force: true) }
                .keyboardShortcut("r")
                .disabled(model.refreshing)
            iconButton("safari", help: "Open gebruik op claude.ai") {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            }
            iconButton("power", help: "Stop Claude Usage (⌘Q)", action: onQuit)
                .keyboardShortcut("q")
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
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
    private let model = UsageModel()
    private var panel: UsageWindow!
    private var hosting: NSHostingView<UsagePanel>!
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
        }
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.renderTitle()
                    if self?.panel.isVisible == true { self?.positionPanel() }
                }
            }
            .store(in: &bag)

        renderTitle()
        model.refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.model.refresh(force: false)
        }
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

        hosting = NSHostingView(rootView: UsagePanel(model: model, onQuit: { NSApp.terminate(nil) }))
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
        if let last = model.lastUpdate, Date().timeIntervalSince(last) > 60 { model.refresh(force: false) }
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

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let s = NSMutableAttributedString(string: "✳︎ ", attributes: [.font: font])
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
        button.toolTip = "Claude-gebruik: sessie · week"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
