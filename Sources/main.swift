import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - Model

struct Window {
    let key: String
    let label: String
    let utilization: Double
    let resetsAt: Date?
}

struct ExtraUsage {
    let used: Double
    let limit: Double
    let currency: String
    let utilization: Double
    let enabled: Bool
}

struct Usage {
    let windows: [Window]
    let extra: ExtraUsage?
    let fetchedAt: Date
    /// True when the numbers came from Claude Code's on-disk cache rather than the API.
    let fromCache: Bool

    var binding: Window? {
        windows.max(by: { $0.utilization < $1.utilization })
    }

    /// Older than two missed polls. A live reading that stops refreshing is just
    /// as stale as a cached one, and used to display with no marker at all.
    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 660
    }
}

// MARK: - Fetching

enum FetchError: Error {
    case noToken
    case http(Int, retryAfter: TimeInterval?)
    case malformed
}

/// Windows the API returns that are worth surfacing, in display order.
/// The API also returns a long tail of null-valued codenamed buckets; those are skipped.
let knownWindows: [(String, String)] = [
    ("five_hour", "5-hour"),
    ("seven_day", "7-day"),
    ("seven_day_opus", "7-day Opus"),
    ("seven_day_sonnet", "7-day Sonnet"),
    ("seven_day_oauth_apps", "7-day apps"),
]

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseDate(_ s: Any?) -> Date? {
    guard let s = s as? String else { return nil }
    if let d = isoFormatter.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}

func parseUsage(_ root: [String: Any], fetchedAt: Date, fromCache: Bool) -> Usage {
    var windows: [Window] = []
    for (key, label) in knownWindows {
        guard let entry = root[key] as? [String: Any],
              let util = entry["utilization"] as? Double else { continue }
        windows.append(Window(key: key, label: label, utilization: util,
                              resetsAt: parseDate(entry["resets_at"])))
    }

    var extra: ExtraUsage?
    if let e = root["extra_usage"] as? [String: Any],
       let used = e["used_credits"] as? Double,
       let limit = e["monthly_limit"] as? Double {
        extra = ExtraUsage(used: used,
                           limit: limit,
                           currency: (e["currency"] as? String) ?? "USD",
                           utilization: (e["utilization"] as? Double) ?? 0,
                           enabled: (e["is_enabled"] as? Bool) ?? false)
    }

    return Usage(windows: windows, extra: extra, fetchedAt: fetchedAt, fromCache: fromCache)
}

func oauthToken() -> String? {
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
          let token = oauth["accessToken"] as? String,
          !token.isEmpty
    else { return nil }
    return token
}

func fetchLive(completion: @escaping (Result<Usage, FetchError>) -> Void) {
    guard let token = oauthToken() else { return completion(.failure(.noToken)) }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 200 else {
            let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return completion(.failure(.http(code, retryAfter: retry)))
        }
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return completion(.failure(.malformed)) }
        completion(.success(parseUsage(root, fetchedAt: Date(), fromCache: false)))
    }.resume()
}

/// Claude Code caches its last utilization fetch in ~/.claude.json. Used when the
/// API call fails so the bar shows a stale-but-real number instead of nothing.
func readCache() -> Usage? {
    let path = NSHomeDirectory() + "/.claude.json"
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cached = root["cachedUsageUtilization"] as? [String: Any],
          let util = cached["utilization"] as? [String: Any]
    else { return nil }
    let ms = (cached["fetchedAtMs"] as? Double) ?? 0
    return parseUsage(util, fetchedAt: Date(timeIntervalSince1970: ms / 1000), fromCache: true)
}

// MARK: - Formatting

/// String(format:) does not honour width specifiers on %@, so pad explicitly.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func bar(_ pct: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((pct / 100.0 * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

func countdown(to date: Date?) -> String {
    guard let date else { return "—" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func ago(_ date: Date) -> String {
    let secs = Int(Date().timeIntervalSince(date))
    if secs < 60 { return "just now" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    return "\(secs / 3600)h ago"
}

func color(for pct: Double) -> NSColor {
    if pct >= 90 { return .systemRed }
    if pct >= 70 { return .systemOrange }
    return .labelColor
}

/// Compact menu-bar label for a window: "5h", "7d", "7d·O".
func shortLabel(_ key: String) -> String {
    switch key {
    case "five_hour": return "5h"
    case "seven_day": return "7d"
    case "seven_day_opus": return "7d·O"
    case "seven_day_sonnet": return "7d·S"
    default: return "7d·a"
    }
}

/// Menu bar segments, one per window shown. Each carries its own utilisation so it
/// can be coloured independently — a healthy 5h should not inherit a red 7d.
func titleSegments(_ u: Usage) -> [(text: String, pct: Double)] {
    let stale = (u.fromCache || u.isStale) ? "~" : ""
    let shown = u.windows.filter { $0.key == "five_hour" || $0.key == "seven_day" }
    let use = shown.isEmpty ? (u.binding.map { [$0] } ?? []) : shown
    return use.map { ("\(shortLabel($0.key)) \(stale)\(Int($0.utilization.rounded()))%", $0.utilization) }
}

func titleText(_ u: Usage) -> String {
    titleSegments(u).map(\.text).joined(separator: "  ")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    var displayTimer: Timer?
    var agents = AgentSnapshot(sessions: [])
    let spinner = SpinnerView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    /// Used to fire only on the busy -> nothing-running edge, not every tick.
    var wasRunning = false
    var usage: Usage?
    var lastError: String?
    /// Swapping item.menu while the user has it open closes it mid-click, so
    /// refreshes that land during tracking defer their rebuild to menuDidClose.
    var menuIsOpen = false
    /// Holding an activity token keeps App Nap from throttling the poll timer.
    var activity: NSObjectProtocol?
    /// Set when the usage endpoint returns 429. Polling past a rate limit only
    /// deepens it, so scheduled refreshes are skipped until this passes.
    var backoffUntil: Date?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Without this, a cmd-dragged position is forgotten on every relaunch.
        item.autosaveName = "ClaudeUsageStatusItem"
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        setTitle("Claude …", pct: 0, dimmed: true)
        refreshAgents()
        rebuildMenu()
        refresh()

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "poll Claude Code usage")

        // Timers do not fire while the machine is asleep, so without this the
        // readout stays frozen at whatever it was when the lid closed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh(manual: true) }

        let t = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Nothing here needs to happen on the dot; slack lets the system batch
        // this wakeup with others instead of waking the CPU on its own.
        t.tolerance = 30
        timer = t

        // Staleness is computed at render time, so without a display-only tick the
        // "~" would never appear precisely when fetching has stopped working.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { _, _ in }

        let display = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshAgents()
            self?.render()
        }
        display.tolerance = 15
        displayTimer = display
    }

    static let barFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    func setTitle(_ text: String, pct: Double, dimmed: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.barFont,
            .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : color(for: pct),
        ]
        item.button?.image = nil
        item.button?.imagePosition = .noImage
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    func setTitle(segments: [(text: String, pct: Double)]) {
        let out = NSMutableAttributedString()
        for (i, seg) in segments.enumerated() {
            if i > 0 {
                out.append(NSAttributedString(string: "  ", attributes: [.font: Self.barFont]))
            }
            out.append(NSAttributedString(string: seg.text, attributes: [
                .font: Self.barFont,
                .foregroundColor: color(for: seg.pct),
            ]))
        }
        item.button?.image = nil
        item.button?.imagePosition = .noImage
        item.button?.attributedTitle = out
    }

    func refresh(manual: Bool = false) {
        if !manual, let until = backoffUntil, until > Date() { return }
        // fetchLive shells out to `security` and blocks on it, so it must not run
        // on the main thread. The completion hops back to main itself.
        DispatchQueue.global(qos: .utility).async {
        fetchLive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let u):
                    self.usage = u
                    self.lastError = nil
                    self.backoffUntil = nil
                case .failure(let e):
                    switch e {
                    case .noToken: self.lastError = "Not signed in to Claude Code"
                    case .http(401, _): self.lastError = "Token expired — run any Claude Code session"
                    case .http(429, let retry):
                        // The endpoint sometimes sends Retry-After: 0 while still
                        // refusing, so a floor is needed or the backoff does nothing.
                        let wait = max(retry ?? 60, 60)
                        self.backoffUntil = Date().addingTimeInterval(wait)
                        self.lastError = "Rate limited — retrying in \(Int(wait))s"
                    case .http(let c, _): self.lastError = "API error \(c)"
                    case .malformed: self.lastError = "Unexpected API response"
                    }
                    // Only fall back to the cache when we have nothing live at all;
                    // a previously-good live reading is fresher than the on-disk one.
                    if self.usage == nil || self.usage?.fromCache == true {
                        self.usage = readCache()
                    }
                }
                self.render()
            }
        }
        }
    }

    func render() {
        guard let u = usage, u.binding != nil else {
            setTitle("Claude ⚠", pct: 0, dimmed: true)
            return
        }
        renderTitle()
        rebuildMenu()
    }

    /// Title only. The spinner runs several times a second, and rebuilding the
    /// whole menu at that rate would be wasteful.
    func renderTitle() {
        guard let u = usage, u.binding != nil else { return }
        var segs = titleSegments(u)
        if let suffix = agentSuffix(agents) {
            segs.append((text: suffix, pct: 0))
        }
        setTitle(segments: segs)
        positionSpinner()
    }

    /// Parks the spinner over the placeholder gap at the start of the suffix.
    func positionSpinner() {
        guard let button = item.button else { return }
        if agents.anyRunning {
            if spinner.superview == nil { button.addSubview(spinner) }
            let x = button.bounds.width - suffixWidth + 1
            spinner.frame = NSRect(x: x, y: (button.bounds.height - 14) / 2 + 1,
                                   width: 14, height: 14)
            spinner.start()
        } else {
            spinner.stop()
            spinner.removeFromSuperview()
        }
    }

    /// Width of the trailing agent suffix, used to place the spinner over its gap.
    var suffixWidth: CGFloat {
        guard let suffix = agentSuffix(agents) else { return 0 }
        return (suffix as NSString)
            .size(withAttributes: [.font: Self.barFont]).width
    }

    func rebuildMenu() {
        guard !menuIsOpen else { return }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        if let u = usage {
            for w in u.windows {
                let line = String(format: "%@ %@ %3d%%   resets %@",
                                  pad(w.label, 12), bar(w.utilization),
                                  Int(w.utilization.rounded()), countdown(to: w.resetsAt))
                let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                mi.attributedTitle = NSAttributedString(string: line, attributes: [
                    .font: mono, .foregroundColor: color(for: w.utilization),
                ])
                menu.addItem(mi)
            }

            if let e = u.extra, e.enabled {
                menu.addItem(.separator())
                let line = String(format: "%@ %@ %3d%%   %@%.0f of %.0f",
                                  pad("Extra usage", 12), bar(e.utilization),
                                  Int(e.utilization.rounded()),
                                  e.currency == "USD" ? "$" : "", e.used, e.limit)
                let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                mi.attributedTitle = NSAttributedString(string: line, attributes: [
                    .font: mono, .foregroundColor: color(for: e.utilization),
                ])
                menu.addItem(mi)
            }

            menu.addItem(.separator())
            let src = u.fromCache ? "cached from Claude Code"
                : (u.isStale ? "stale — refresh to update" : "live")
            menu.addItem(disabled("Updated \(ago(u.fetchedAt)) · \(src)"))
        }

        let mono2 = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        if agents.sessions.isEmpty {
            menu.addItem(disabled("No Claude Code sessions running"))
        } else {
            for a in agents.sessions {
                // Shape carries the status as well as colour, so the rows stay
                // readable without relying on colour alone.
                let (dot, tint): (String, NSColor) = {
                    switch a.status {
                    case "busy":    return ("\u{25CF}", .systemGreen)
                    case "waiting": return ("\u{25D0}", .systemOrange)
                    default:        return ("\u{25CB}", .tertiaryLabelColor)
                    }
                }()

                var line = "\(dot) \(pad(a.label, 36))\(pad(a.status, 8))"
                if a.subagents > 0 { line += "+\(a.subagents) sub" }

                let attributed = NSMutableAttributedString(string: line, attributes: [
                    .font: mono2,
                    .foregroundColor: a.isBusy ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ])
                // Tint only the dot and the status word; the title stays neutral.
                attributed.addAttribute(.foregroundColor, value: tint,
                                        range: NSRange(location: 0, length: 1))
                if let r = line.range(of: a.status, options: .backwards) {
                    attributed.addAttribute(.foregroundColor, value: tint,
                                            range: NSRange(r, in: line))
                }
                let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                mi.attributedTitle = attributed
                menu.addItem(mi)
            }

            let summary = agents.anyRunning
                ? "\(agents.busyCount) busy · \(agents.subagentCount) subagent(s)"
                : "All agents idle — nothing running"
            menu.addItem(disabled(summary))
        }
        menu.addItem(.separator())

        if let err = lastError {
            menu.addItem(disabled("⚠ \(err)"))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(doRefresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Usage Page", action: #selector(openUsage), keyEquivalent: "u"))
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for mi in menu.items where mi.action != nil && mi.action != #selector(NSApplication.terminate(_:)) {
            mi.target = self
        }
        return menu
    }

    func disabled(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        mi.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return mi
    }

    @objc func doRefresh() {
        refreshAgents()
        refresh(manual: true)
    }

    func refreshAgents() {
        let snapshot = agentSnapshot()
        let running = snapshot.anyRunning
        // Only announce the transition, and only after having seen work in flight.
        if wasRunning, !running { notifyAllStopped() }
        wasRunning = running
        agents = snapshot
    }

    func notifyAllStopped() {
        let content = UNMutableNotificationContent()
        content.title = "All agents stopped"
        content.body = agents.sessions.isEmpty
            ? "No Claude Code sessions running."
            : "\(agents.sessions.count) session(s) idle — nothing in flight."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }

    @objc func openUsage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = "Login item failed: \(error.localizedDescription)"
        }
        rebuildMenu()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Opening the menu never fetches; only the timer and "Refresh Now" spend a
        // request. This just applies any rebuild that was deferred while it was open.
        rebuildMenu()
    }
}

// `ClaudeUsage --dump` prints what the menu bar would show and exits. The status
// bar itself is invisible to screencapture, so this is how the data path is checked.
if CommandLine.arguments.contains("--agents") {
    let snap = agentSnapshot()
    if snap.sessions.isEmpty {
        print("No Claude Code sessions running")
    } else {
        for a in snap.sessions {
            print(String(format: "%@ %@ %@ subagents=%d",
                         pad(String(a.pid), 8), pad(a.label, 36), pad(a.status, 9), a.subagents))
        }
        print("---")
        print("agents=\(snap.sessions.count) busy=\(snap.busyCount) subagents=\(snap.subagentCount)")
        print(snap.anyRunning ? "something is running" : "ALL AGENTS STOPPED")
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    let sem = DispatchSemaphore(value: 0)
    var result: Usage?
    var err: String?
    if CommandLine.arguments.contains("--cache-only") {
        result = readCache()
        sem.signal()
    } else {
    fetchLive { r in
        switch r {
        case .success(let u): result = u
        case .failure(let e): err = "\(e)"; result = readCache()
        }
        sem.signal()
    }
    }
    _ = sem.wait(timeout: .now() + 20)
    if let e = err { print("live fetch failed: \(e)") }
    guard let u = result else { print("no usage available"); exit(1) }
    var barText = titleText(u)
    if let suffix = agentSuffix(agentSnapshot()) { barText += "  " + suffix }
    print("menu bar: \(barText)")
    for w in u.windows {
        print(String(format: "  %@ %@ %3d%%   resets %@", pad(w.label, 12),
                     bar(w.utilization), Int(w.utilization.rounded()), countdown(to: w.resetsAt)))
    }
    if let e = u.extra, e.enabled {
        print(String(format: "  %@ %@ %3d%%   %.0f of %.0f %@", pad("Extra usage", 12),
                     bar(e.utilization), Int(e.utilization.rounded()), e.used, e.limit, e.currency))
    }
    print("  updated \(ago(u.fetchedAt)) · \(u.fromCache ? "cached" : "live")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
