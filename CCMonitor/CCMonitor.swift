// CCMonitor — a small always-on-top panel that monitors live Claude Code sessions
// and jumps Terminal.app to the tab running whichever one you click.
import AppKit
import SwiftUI
import UserNotifications

// MARK: - model

struct Session: Identifiable, Equatable {
    var id: String              // sessionId
    var pid: Int32
    var cwd: String
    var name: String
    var status: String          // "busy" | "shell" | "idle" | "waiting"
    var waitingFor: String = ""  // "dialog open" | "input needed" | "goal proposal" | "sandbox request"
    var updatedAt: Double       // epoch seconds
    var startedAt: Double
    var tty: String = ""
    var windowLabel: String = ""
    var cpu: Double = 0          // % of one core, whole process tree
    var rssBytes: Double = 0     // resident memory, whole process tree
    var procs: Int = 0           // processes in the tree
    var project: String {
        let b = (cwd as NSString).lastPathComponent
        return b.isEmpty ? cwd : b
    }

    /// Claude is blocked on the human: a dialog, a question, a sandbox request.
    var needsYou: Bool { status == "waiting" }
    /// Nothing running — the turn is over and it is your move.
    var isIdle: Bool { status == "idle" }
    var isWorking: Bool { status == "busy" || status == "shell" }

    var stateLabel: String {
        switch status {
        case "waiting":
            switch waitingFor {
            case "dialog open":     return "needs approval"
            case "input needed":    return "asked you"
            case "goal proposal":   return "wants a goal"
            case "sandbox request": return "sandbox ask"
            default:                return waitingFor.isEmpty ? "waiting" : waitingFor
            }
        case "shell": return "running"
        case "busy":  return "working"
        case "idle":  return "your turn"
        default:      return status
        }
    }
}

/// Everything one scan produced. Immutable, handed to the main actor as a unit.
struct Snapshot: Equatable {
    var sessions: [Session] = []
    var tabs: [TermTab] = []
    var load1: Double = 0
    var cores: Int = 1
    var claudeCPU: Double = 0
    var claudeRSS: Double = 0
    var totalRAM: Double = 1
}

struct TermTab: Identifiable, Equatable {
    var id: String { tty }
    var window: Int
    var tab: Int
    var tty: String
    var busy: Bool
    var title: String
    var procs: [String]
    var cwd: String = ""
    var hasClaude: Bool { procs.contains { $0.hasSuffix("claude") } }
    /// What to show when the tab has no custom title: the most interesting process.
    var procLabel: String {
        let ignore: Set<String> = ["login", "-zsh", "zsh", "-bash", "bash", "caffeinate"]
        if let p = procs.last(where: { !ignore.contains($0) }) { return p }
        return procs.last.map { $0.hasPrefix("-") ? String($0.dropFirst()) : $0 } ?? "shell"
    }
    var dirLabel: String {
        let home = NSHomeDirectory()
        if cwd.isEmpty { return "" }
        if cwd == home { return "~" }
        return (cwd as NSString).lastPathComponent
    }
    /// Main line: a custom title if Terminal has one, else the directory, else the process.
    var label: String {
        if !title.isEmpty && title != "Terminal" { return title }
        if !dirLabel.isEmpty { return dirLabel }
        return procLabel
    }
}

func bytes(_ b: Double) -> String {
    let gb = 1073741824.0, mb = 1048576.0
    if b >= gb { return String(format: "%.1f GB", b / gb) }
    if b >= mb { return String(format: "%.0f MB", b / mb) }
    return String(format: "%.0f KB", b / 1024)
}

func humanAge(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func shell(_ launch: String, _ args: [String], timeout: Double = 8) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// All scanning happens on one serial queue, so nothing here is ever touched by
/// two threads at once, and a slow pass can never overlap the next tick.
/// Costs matter: an AppleScript pass over 30+ Terminal windows takes seconds,
/// so each source has its own cadence and only runs when it earns its keep.
final class Scanner {
    static let shared = Scanner()
    let queue = DispatchQueue(label: "ccmonitor.scan", qos: .utility)

    // cadences, seconds (panel visible / panel hidden)
    private let sessionEvery = (2.0, 8.0)
    private let psEvery      = (6.0, 30.0)
    private let tabsEvery    = (25.0, Double.infinity)   // AppleScript: never when hidden
    private let cwdEvery     = (60.0, Double.infinity)

    private var lastSessions = Date.distantPast
    private var lastPS = Date.distantPast
    private var lastTabs = Date.distantPast
    private var lastCwd = Date.distantPast
    private var lastSnapshotWrite = Date.distantPast

    private var ttyCache: [Int32: String] = [:]
    private var cwdCache: [String: String] = [:]       // tty -> cwd
    private var windowMap: [String: String] = [:]      // tty -> "w6"
    private var claudeTTYs: Set<String> = []
    private var alivePIDs: Set<Int32> = []
    private var snap = Snapshot()
    private var tabList: [TermTab] = []
    private var scanning = false

    var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }
    var stateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ccm")
    }

    // MARK: one tick

    /// Called from the main actor; returns immediately. `done` runs on the main queue.
    func tick(visible: Bool, done: @escaping (Snapshot) -> Void) {
        queue.async {
            guard !self.scanning else { return }        // a slow pass must not overlap
            self.scanning = true
            defer { self.scanning = false }

            let now = Date()
            let i = visible ? 0 : 1
            let sessionGate = [self.sessionEvery.0, self.sessionEvery.1][i]
            let psGate      = [self.psEvery.0, self.psEvery.1][i]
            let tabsGate    = [self.tabsEvery.0, self.tabsEvery.1][i]
            let cwdGate     = [self.cwdEvery.0, self.cwdEvery.1][i]

            if now.timeIntervalSince(self.lastPS) >= psGate {
                self.refreshProcessTable()
                self.lastPS = now
            }
            if now.timeIntervalSince(self.lastTabs) >= tabsGate {
                self.refreshTabs()
                self.lastTabs = now
            }
            if now.timeIntervalSince(self.lastCwd) >= cwdGate {
                self.refreshCwds()
                self.lastCwd = now
            }
            if now.timeIntervalSince(self.lastSessions) >= sessionGate {
                self.refreshSessions()
                self.lastSessions = now
            }
            if now.timeIntervalSince(self.lastSnapshotWrite) >= 30 {
                self.writeSnapshot()
                self.lastSnapshotWrite = now
            }
            let out = self.snap
            DispatchQueue.main.async { done(out) }
        }
    }

    /// Force the expensive sources on the next tick (panel just opened, user hit refresh).
    func invalidate() {
        queue.async {
            self.lastTabs = .distantPast
            self.lastPS = .distantPast
            self.lastSessions = .distantPast
        }
    }

    // MARK: sources

    /// One `ps` pass answers liveness, which ttys run claude, and per-session
    /// CPU/memory summed over each session's whole process tree.
    private func refreshProcessTable() {
        let out = shell("/bin/ps", ["-axo", "pid=,ppid=,tty=,pcpu=,rss=,comm="])
        guard !out.isEmpty else { return }
        var kids: [Int32: [Int32]] = [:]
        var own: [Int32: (Double, Double)] = [:]
        var alive = Set<Int32>()
        var ttys = Set<String>()
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 6, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            let comm = f[5...].joined(separator: " ")
            alive.insert(pid)
            own[pid] = (Double(f[3]) ?? 0, (Double(f[4]) ?? 0) * 1024)
            kids[ppid, default: []].append(pid)
            if f[2].hasPrefix("ttys"), comm.hasSuffix("claude") { ttys.insert("/dev/" + f[2]) }
        }
        alivePIDs = alive
        claudeTTYs = ttys
        treeCache = (kids, own)
    }

    private var treeCache: ([Int32: [Int32]], [Int32: (Double, Double)]) = ([:], [:])

    private func treeUsage(_ pid: Int32) -> (cpu: Double, rss: Double, n: Int) {
        let (kids, own) = treeCache
        func walk(_ p: Int32, _ d: Int) -> (Double, Double, Int) {
            guard d < 12, let mine = own[p] else { return (0, 0, 0) }
            var cpu = mine.0, rss = mine.1, n = 1
            for k in kids[p] ?? [] {
                let t = walk(k, d + 1)
                cpu += t.0; rss += t.1; n += t.2
            }
            return (cpu, rss, n)
        }
        let r = walk(pid, 0)
        return (r.0, r.1, r.2)
    }

    private func alive(_ pid: Int32) -> Bool {
        if !alivePIDs.isEmpty { return alivePIDs.contains(pid) }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func tty(for pid: Int32) -> String {
        if let t = ttyCache[pid] { return t }
        let raw = shell("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])
        let t = (raw.isEmpty || raw == "??") ? "" : "/dev/" + raw
        ttyCache[pid] = t
        return t
    }

    /// Which directory is each shell sitting in? One ps + one batched lsof.
    private func refreshCwds() {
        let ps = shell("/bin/ps", ["-axo", "pid=,tty=,comm="])
        var pidTTY: [String: String] = [:]
        for line in ps.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 3, f[1].hasPrefix("ttys") else { continue }
            let comm = f[2...].joined(separator: " ")
            guard comm.hasSuffix("zsh") || comm.hasSuffix("bash") || comm.hasSuffix("fish") else { continue }
            pidTTY[f[0]] = "/dev/" + f[1]
        }
        guard !pidTTY.isEmpty else { return }
        let out = shell("/usr/sbin/lsof",
                        ["-a", "-d", "cwd", "-Fpn", "-p", pidTTY.keys.joined(separator: ",")])
        var cur = ""
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { cur = String(line.dropFirst()) }
            else if line.hasPrefix("n"), let tty = pidTTY[cur] { map[tty] = String(line.dropFirst()) }
        }
        if !map.isEmpty { cwdCache = map }
    }

    /// The expensive one: Terminal's window/tab inventory over AppleScript.
    private func refreshTabs() {
        let script = """
        set AppleScript's text item delimiters to ","
        tell application "Terminal"
          set out to ""
          repeat with w from 1 to count windows
            repeat with t from 1 to count tabs of window w
              set tb to tab t of window w
              set nm to ""
              try
                set nm to custom title of tb
              end try
              set out to out & w & "|" & t & "|" & (tty of tb) & "|" & (busy of tb) & "|" & nm & linefeed
            end repeat
          end repeat
          return out
        end tell
        """
        let out = shell("/usr/bin/osascript", ["-e", script], timeout: 20)
        guard !out.isEmpty else { return }
        var found: [TermTab] = []
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let f = line.components(separatedBy: "|")
            guard f.count >= 5 else { continue }
            let tty = f[2]
            map[tty] = "w" + f[0]
            found.append(TermTab(window: Int(f[0]) ?? 0,
                                 tab: Int(f[1]) ?? 0,
                                 tty: tty,
                                 busy: f[3] == "true",
                                 title: f[4].trimmingCharacters(in: .whitespaces),
                                 procs: claudeTTYs.contains(tty) ? ["claude"] : [],
                                 cwd: cwdCache[tty] ?? ""))
        }
        if !map.isEmpty { windowMap = map }
        tabList = found
    }

    private func refreshSessions() {
        var out: [Session] = []
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidNum = obj["pid"] as? NSNumber,
                  let sid = obj["sessionId"] as? String else { continue }
            let pid = pidNum.int32Value
            guard alive(pid) else { continue }
            let t = tty(for: pid)
            let usage = treeUsage(pid)
            var s = Session(
                id: sid, pid: pid,
                cwd: obj["cwd"] as? String ?? "",
                name: obj["name"] as? String ?? "",
                status: obj["status"] as? String ?? "",
                waitingFor: obj["waitingFor"] as? String ?? "",
                updatedAt: ((obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                startedAt: ((obj["startedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                tty: t,
                windowLabel: windowMap[t] ?? "",
                cpu: usage.cpu, rssBytes: usage.rss, procs: usage.n
            )
            if s.updatedAt == 0 { s.updatedAt = s.startedAt }
            out.append(s)
        }
        func rank(_ s: Session) -> Int {
            if s.needsYou { return 0 }
            if s.isWorking { return 1 }
            return 2
        }
        out.sort { rank($0) != rank($1) ? rank($0) < rank($1) : $0.updatedAt > $1.updatedAt }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let liveTTYs = Set(out.map { $0.tty })
        snap = Snapshot(
            sessions: out,
            tabs: tabList.filter { !liveTTYs.contains($0.tty) }
                         .sorted { (($0.hasClaude ? 0 : ($0.busy ? 1 : 2)), $0.window)
                                 < (($1.hasClaude ? 0 : ($1.busy ? 1 : 2)), $1.window) },
            load1: loads[0],
            cores: ProcessInfo.processInfo.activeProcessorCount,
            claudeCPU: out.reduce(0) { $0 + $1.cpu },
            claudeRSS: out.reduce(0) { $0 + $1.rssBytes },
            totalRAM: Double(ProcessInfo.processInfo.physicalMemory)
        )
    }

    // MARK: snapshot + restore

    /// Write what is running now, so it can be brought back after a crash or reboot.
    private func writeSnapshot() {
        guard !snap.sessions.isEmpty else { return }
        let payload: [String: Any] = [
            "savedAt": Date().timeIntervalSince1970,
            "sessions": snap.sessions.map {
                ["sessionId": $0.id, "cwd": $0.cwd, "name": $0.name,
                 "status": $0.status, "window": $0.windowLabel]
            },
            "windows": snap.tabs.compactMap { t -> [String: Any]? in
                t.cwd.isEmpty ? nil : ["cwd": t.cwd, "title": t.title]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let cur = stateDir.appendingPathComponent("snapshot.json")
        let prev = stateDir.appendingPathComponent("snapshot.prev.json")
        let tmp = stateDir.appendingPathComponent("snapshot.tmp")
        try? data.write(to: tmp)
        if fm.fileExists(atPath: cur.path) {
            try? fm.removeItem(at: prev)
            try? fm.copyItem(at: cur, to: prev)
        }
        _ = try? fm.replaceItemAt(cur, withItemAt: tmp)
    }

    // MARK: actions

    func jump(to s: Session) { jump(tty: s.tty) }

    func jump(tty: String) {
        guard !tty.isEmpty else { NSSound.beep(); return }
        let script = """
        tell application "Terminal"
          repeat with w from 1 to count windows
            repeat with t from 1 to count tabs of window w
              if (tty of tab t of window w) is "\(tty)" then
                set selected tab of window w to tab t of window w
                set index of window w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "notfound"
        """
        if shell("/usr/bin/osascript", ["-e", script], timeout: 20) != "ok" { NSSound.beep() }
    }

    func openTUI(_ args: String = "") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = """
        tell application "Terminal"
          activate
          do script "\(home)/.local/bin/ccm \(args)"
        end tell
        """
        _ = shell("/usr/bin/osascript", ["-e", script])
    }
}

// MARK: - notifications

/// Local notifications, with a fallback for when this ad-hoc-signed bundle
/// is not allowed to post them itself.
final class Notifier {
    static let shared = Notifier()
    private var authorized = false
    private var asked = false

    func prepare() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { ok, _ in
                self.authorized = ok
            }
    }

    func post(title: String, body: String, urgent: Bool) {
        if authorized {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            if urgent { c.sound = .default }
            let r = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
            UNUserNotificationCenter.current().add(r) { err in
                if err != nil { self.fallback(title: title, body: body) }
            }
        } else {
            fallback(title: title, body: body)
        }
    }

    private func fallback(title: String, body: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        _ = shell("/usr/bin/osascript",
                  ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
    }
}

// MARK: - view model

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var others: [TermTab] = []
    @Published var stats = Snapshot()
    @Published var tick: Date = Date()
    private var timer: Timer?
    private var lastState: [String: String] = [:]     // sessionId -> status
    private var busySince: [String: Date] = [:]

    init() { refresh(); start() }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Fire a notification when a session starts needing you, or finishes a long task.
    func noteTransitions(_ fresh: [Session]) {
        let terminalFront = AppDelegate.shared?.terminalIsFront ?? false
        let notify = UserDefaults.standard.object(forKey: "notify") as? Bool ?? true
        for s in fresh {
            let prev = lastState[s.id]
            lastState[s.id] = s.status
            if s.isWorking && busySince[s.id] == nil { busySince[s.id] = Date() }

            guard let prev, prev != s.status, notify, !terminalFront else {
                if !s.isWorking { busySince[s.id] = nil }
                continue
            }
            if s.needsYou {
                Notifier.shared.post(title: "\(s.project) needs you",
                                     body: s.stateLabel + (s.name.isEmpty ? "" : " · \(s.name)"),
                                     urgent: true)
            } else if s.isIdle, let began = busySince[s.id], Date().timeIntervalSince(began) > 25 {
                Notifier.shared.post(title: "\(s.project) finished",
                                     body: s.name.isEmpty ? "waiting for your next step" : s.name,
                                     urgent: false)
            }
            if !s.isWorking { busySince[s.id] = nil }
        }
        let goneIDs = Set(lastState.keys).subtracting(fresh.map { $0.id })
        for id in goneIDs { lastState[id] = nil; busySince[id] = nil }
    }

    func refresh() {
        let visible = AppDelegate.shared?.panelOnScreen ?? true
        Scanner.shared.tick(visible: visible) { [weak self] snap in
            guard let self else { return }
            self.noteTransitions(snap.sessions)
            var changed = false
            if snap.sessions != self.sessions { self.sessions = snap.sessions; changed = true }
            if snap.tabs != self.others { self.others = snap.tabs; changed = true }
            if snap.load1 != self.stats.load1 || snap.claudeCPU != self.stats.claudeCPU {
                self.stats = snap; changed = true
            }
            // `tick` only exists to age the timestamps, so it does not need to fire
            // every cycle — re-rendering 40 rows twice a second is not free.
            if changed || Date().timeIntervalSince(self.tick) > 10 { self.tick = Date() }
            AppDelegate.shared?.updateStatusItem(snap.sessions)
        }
    }
}

// MARK: - views

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct Row: View {
    let s: Session
    let now: Date
    @State private var hover = false

    @State private var breathe = false

    /// Only a session that is blocked on you blinks. Ten working sessions each
    /// animating a dot forever measured 8% of a core on an 8-core machine — the
    /// colour already says "working", so it does not need to move.
    var animated: Bool { s.needsYou }

    var color: Color {
        if s.needsYou { return .pink }
        switch s.status {
        case "busy":  return .orange
        case "shell": return .cyan
        case "idle":  return .green
        default:      return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(animated ? (breathe ? 0.35 : 1) : 1)
                .animation(animated
                           ? .easeInOut(duration: s.needsYou ? 0.45 : 0.9).repeatForever()
                           : .default,
                           value: breathe)
                .onAppear { if animated { breathe = true } }
                .onChange(of: animated) { _, on in breathe = on }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(s.project).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if s.needsYou {
                        Text(s.stateLabel.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.pink.opacity(0.9)))
                            .foregroundStyle(.white)
                    }
                }
                Text(s.needsYou ? (s.name.isEmpty ? s.cwd : s.name)
                                : "\(s.stateLabel) · \(s.name.isEmpty ? s.cwd : s.name)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                Button {
                    let a = NSAlert()
                    a.messageText = "Quit this Claude session?"
                    a.informativeText = "\(s.project) — pid \(s.pid)"
                    a.addButton(withTitle: "Quit session")
                    a.addButton(withTitle: "Cancel")
                    a.alertStyle = .warning
                    if a.runModal() == .alertFirstButtonReturn { kill(s.pid, SIGTERM) }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Terminate this session")
            }
            Text(s.windowLabel).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            if s.cpu > 0 {
                Text(s.cpu >= 100 ? "\(Int(s.cpu))%" : String(format: "%.0f%%", s.cpu))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(s.cpu > 90 ? .orange : .secondary)
                    .frame(width: 30, alignment: .trailing)
                    .help("\(String(format: "%.0f", s.cpu))% of one core · \(bytes(s.rssBytes)) · \(s.procs) processes")
            }
            Text(humanAge(now.timeIntervalSince1970 - s.updatedAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(s.status == "busy" ? .primary : .secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hover ? Color.primary.opacity(0.10)
                        : (s.needsYou ? Color.pink.opacity(0.14) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { Scanner.shared.jump(to: s) }
        .help("Click to jump to this session's Terminal tab")
    }
}

struct OtherRow: View {
    let t: TermTab
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(t.hasClaude ? Color.yellow.opacity(0.75)
                                  : (t.busy ? Color.blue.opacity(0.65) : Color.secondary.opacity(0.4)))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.label)
                    .font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(t.hasClaude ? .primary : .secondary)
                if t.hasClaude {
                    Text("claude · no session file")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                } else if t.busy {
                    Text(t.procLabel).font(.system(size: 9))
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text("w\(t.window)").font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary).frame(width: 20, alignment: .trailing)
            Text(t.busy ? "run" : "—").font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hover ? Color.primary.opacity(0.10) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { Scanner.shared.jump(tty: t.tty) }
        .help((t.cwd.isEmpty ? t.tty : t.cwd) + " — click to bring this window forward")
    }
}

/// Load, and what Claude is costing. On a small Mac this is the number that
/// explains why everything feels slow.
struct PerfStrip: View {
    let snap: Snapshot

    var pressure: Double { snap.cores > 0 ? snap.load1 / Double(snap.cores) : 0 }
    var color: Color { pressure > 2 ? .red : (pressure > 1 ? .orange : .green) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("load \(String(format: "%.1f", snap.load1))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                Text("/ \(snap.cores) cores")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("claude \(String(format: "%.0f", snap.claudeCPU))% · \(bytes(snap.claudeRSS))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(snap.claudeRSS > snap.totalRAM * 0.6 ? .orange : .secondary)
                .help("Total CPU and resident memory of every live session's process tree, "
                      + "against \(bytes(snap.totalRAM)) of RAM")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(pressure > 2 ? Color.red.opacity(0.10) : Color.clear)
        .help(pressure > 2
              ? "Load is more than twice the core count — sessions are queueing for CPU"
              : "System load over the last minute")
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }
}

struct PanelView: View {
    @ObservedObject var store: Store

    var busy: Int { store.sessions.filter { $0.isWorking }.count }
    var needs: Int { store.sessions.filter { $0.needsYou }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Claude sessions").font(.system(size: 11, weight: .semibold))
                Spacer()
                if needs > 0 {
                    Text("\(needs) need you")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.pink)
                }
                Text("\(busy) busy · \(store.sessions.count) live · \(store.others.count) other")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 5)

            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 1) {
                    if store.sessions.isEmpty {
                        Text("no live Claude sessions")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(store.sessions) { s in Row(s: s, now: store.tick) }
                    }

                    if !store.others.isEmpty {
                        SectionLabel(text: "other terminal windows (\(store.others.count))")
                        ForEach(store.others) { t in OtherRow(t: t) }
                    }
                }.padding(.horizontal, 4).padding(.vertical, 4)
            }

            Divider().opacity(0.4)
            PerfStrip(snap: store.stats)
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Button("ccm") { Scanner.shared.openTUI() }
                    .buttonStyle(.plain).font(.system(size: 10))
                    .foregroundStyle(.secondary).help("Open the full session organizer in Terminal")
                Spacer()
                Text("click a row to jump").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .background(Blur().ignoresSafeArea())
    }
}

// MARK: - app

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    var panel: Panel!
    var statusItem: NSStatusItem!
    var loginItem: NSMenuItem!
    var followItem: NSMenuItem!
    var notifyItem: NSMenuItem!
    var restoreItem: NSMenuItem!
    /// True while Terminal (or our own alert) owns the screen.
    var terminalIsFront = false
    var followTerminal: Bool {
        (UserDefaults.standard.object(forKey: "followTerminal") as? Bool) ?? true
    }
    /// Is the panel actually on screen? Drives how hard the scanner works.
    var panelOnScreen: Bool { panel?.isVisible ?? false }
    var panelWanted: Bool {
        (UserDefaults.standard.object(forKey: "panelVisible") as? Bool) ?? true
    }
    let agentLabel = "local.nakas.ccmonitor"
    var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.nakas.ccmonitor.plist")
    }
    let store = Store()

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        let saved = UserDefaults.standard.string(forKey: "panelFrame")
        var frame = saved.map { NSRectFromString($0) } ?? NSRect(x: 60, y: 60, width: 320, height: 420)
        if let vis = NSScreen.main?.visibleFrame {
            frame.size.width = min(max(frame.width, 260), vis.width)
            frame.size.height = min(max(frame.height, 200), vis.height)
            frame.origin.x = min(max(frame.minX, vis.minX), vis.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, vis.minY), vis.maxY - frame.height)
        }

        panel = Panel(contentRect: frame,
                      styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.title = "Claude"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PanelView(store: store))
        panel.setFrame(frame, display: true)
        panel.delegate = self
        // At launch WE are usually the frontmost app (`open` activated us), so asking
        // "is Terminal in front?" has to look past ourselves.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        terminalIsFront = (front == "com.apple.Terminal") || (front == Bundle.main.bundleIdentifier)
        applyVisibility()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    self?.frontAppChanged(app?.bundleIdentifier)
                }
        }
        Notifier.shared.prepare()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.title = "◌"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Show / hide panel", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open ccm in Terminal", action: #selector(openTUI), keyEquivalent: ""))
        restoreItem = NSMenuItem(title: "Restore sessions from snapshot…",
                                 action: #selector(restoreSnapshot), keyEquivalent: "")
        menu.addItem(restoreItem)
        menu.addItem(.separator())
        followItem = NSMenuItem(title: "Show only with Terminal", action: #selector(toggleFollow), keyEquivalent: "")
        menu.addItem(followItem)
        notifyItem = NSMenuItem(title: "Notify when a session needs me", action: #selector(toggleNotify), keyEquivalent: "")
        menu.addItem(notifyItem)
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Start automatically", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CCMonitor", action: #selector(quit), keyEquivalent: "q"))
        for i in menu.items { i.target = self }
        statusItem.menu = menu
        refreshLoginItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.offerRestoreIfEverythingIsGone()
        }
    }

    /// The panel rides along with Terminal: visible when Terminal is in front,
    /// out of the way otherwise. The menu bar item carries the state meanwhile.
    func frontAppChanged(_ bundleID: String?) {
        let mine = Bundle.main.bundleIdentifier
        if bundleID == mine { return }                  // our own alert — leave things alone
        terminalIsFront = (bundleID == "com.apple.Terminal")
        applyVisibility()
    }

    func applyVisibility() {
        let show = panelWanted && (!followTerminal || terminalIsFront)
        if show {
            if !panel.isVisible {
                panel.orderFrontRegardless()
                Scanner.shared.invalidate()      // freshen the cheap-but-stale sources
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Bring back the sessions from the last snapshot, one Terminal window each.
    @objc func restoreSnapshot() {
        let file = Scanner.shared.stateDir.appendingPathComponent("snapshot.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saved = obj["sessions"] as? [[String: Any]], !saved.isEmpty else {
            let a = NSAlert()
            a.messageText = "No snapshot yet"
            a.informativeText = "CCMonitor writes one every 30 seconds while sessions are running."
            a.runModal()
            return
        }
        let liveIDs = Set(store.sessions.map { $0.id })
        let missing = saved.filter { !liveIDs.contains(($0["sessionId"] as? String) ?? "") }
        let when = (obj["savedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let fmt = RelativeDateTimeFormatter()

        let a = NSAlert()
        a.messageText = missing.isEmpty ? "Everything is already running"
                                        : "Restore \(missing.count) session\(missing.count == 1 ? "" : "s")?"
        a.informativeText = missing.isEmpty
            ? "The snapshot from \(fmt.localizedString(for: when, relativeTo: Date())) holds \(saved.count) sessions, all live."
            : missing.compactMap { $0["cwd"] as? String }
                     .map { ($0 as NSString).lastPathComponent }
                     .joined(separator: ", ")
              + "\n\nSnapshot from \(fmt.localizedString(for: when, relativeTo: Date())). Each opens a Terminal window resuming that session."
        if missing.isEmpty { a.runModal(); return }
        a.addButton(withTitle: "Restore")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Scanner.shared.queue.async {
            for row in missing {
                guard let sid = row["sessionId"] as? String,
                      let cwd = row["cwd"] as? String else { continue }
                let cmd = "cd \(shellQuote(cwd)) && claude --resume \(sid)"
                _ = shell("/usr/bin/osascript",
                          ["-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
                Thread.sleep(forTimeInterval: 1.2)   // let each session boot before the next
            }
        }
    }

    func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "panelFrame")
    }

    func updateStatusItem(_ sessions: [Session]) {
        guard let button = statusItem?.button else { return }
        let busy = sessions.filter { $0.isWorking }.count
        let needs = sessions.filter { $0.needsYou }.count
        let live = sessions.count
        let base = live == 0 ? "◌" : (busy > 0 ? "◉\(busy)" : "○\(live)")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: needs > 0 ? .bold : .regular)
        let title = NSMutableAttributedString(
            string: base, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if needs > 0 {
            title.append(NSAttributedString(
                string: "  ✦\(needs)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                             .foregroundColor: NSColor.systemPink]))
        }
        button.attributedTitle = title
        button.toolTip = needs > 0
            ? sessions.filter { $0.needsYou }
                      .map { "\($0.project): \($0.stateLabel)" }.joined(separator: "\n")
            : "\(busy) working · \(live) live Claude sessions"
    }

    @objc func toggle() {
        UserDefaults.standard.set(!panel.isVisible, forKey: "panelVisible")
        applyVisibility()
        if panelWanted && !panel.isVisible {
            // asked for it while Terminal is in the background: show it anyway
            panel.orderFrontRegardless()
        }
    }

    @objc func toggleFollow() {
        UserDefaults.standard.set(!followTerminal, forKey: "followTerminal")
        applyVisibility()
        refreshLoginItem()
    }

    @objc func toggleNotify() {
        let on = (UserDefaults.standard.object(forKey: "notify") as? Bool) ?? true
        UserDefaults.standard.set(!on, forKey: "notify")
        if !on { Notifier.shared.prepare() }
        refreshLoginItem()
    }

    /// Enable or disable the launchd agent that keeps the menu bar item alive.
    @objc func toggleLogin() {
        let uid = getuid()
        let on = FileManager.default.fileExists(atPath: agentPlist.path)
        if on {
            _ = shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
            try? FileManager.default.removeItem(at: agentPlist)
        } else {
            writeAgentPlist()
            _ = shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentPlist.path])
        }
        refreshLoginItem()
    }

    func writeAgentPlist() {
        let exe = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        try? FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0) {
            try? data.write(to: agentPlist)
        }
    }

    func refreshLoginItem() {
        loginItem?.state = FileManager.default.fileExists(atPath: agentPlist.path) ? .on : .off
        followItem?.state = followTerminal ? .on : .off
        notifyItem?.state = ((UserDefaults.standard.object(forKey: "notify") as? Bool) ?? true) ? .on : .off
    }
    @objc func openTUI() { Scanner.shared.openTUI() }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItem()
        let n = restorableCount()
        restoreItem?.title = n > 0
            ? "Restore \(n) session\(n == 1 ? "" : "s") from snapshot…"
            : "Restore sessions from snapshot…"
        restoreItem?.isEnabled = true
    }

    /// Sessions in the last snapshot that are not running now.
    func restorableCount() -> Int {
        let file = Scanner.shared.stateDir.appendingPathComponent("snapshot.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saved = obj["sessions"] as? [[String: Any]] else { return 0 }
        let live = Set(store.sessions.map { $0.id })
        return saved.filter { !live.contains(($0["sessionId"] as? String) ?? "") }.count
    }

    /// If the snapshot holds sessions and none of them are running, something took
    /// them down — say so once, rather than waiting to be asked.
    func offerRestoreIfEverythingIsGone() {
        guard store.sessions.isEmpty else { return }
        let n = restorableCount()
        guard n >= 2 else { return }
        Notifier.shared.post(title: "\(n) Claude sessions are not running",
                             body: "Restore them from the last snapshot in the CCMonitor menu",
                             urgent: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        UserDefaults.standard.set(false, forKey: "panelVisible")
        return true
    }
    @objc func quit() { NSApp.terminate(nil) }
}

@main
struct CCMonitorMain {
    static func main() {
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
