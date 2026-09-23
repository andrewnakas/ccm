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

func humanAge(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
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

final class Scanner {
    static let shared = Scanner()
    private var ttyCache: [Int32: String] = [:]
    private var windowMap: [String: String] = [:]     // "/dev/ttys033" -> "w6"
    private var windowMapAt: Date = .distantPast

    var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    func alive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    func tty(for pid: Int32) -> String {
        if let t = ttyCache[pid] { return t }
        let raw = shell("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])
        let t = (raw.isEmpty || raw == "??") ? "" : "/dev/" + raw
        ttyCache[pid] = t
        return t
    }

    private(set) var tabs: [TermTab] = []
    private var cwdCache: [String: String] = [:]      // tty -> cwd
    private var cwdAt: Date = .distantPast

    /// Which directory is each shell sitting in? Two calls for every window at once.
    func refreshCwds() {
        guard Date().timeIntervalSince(cwdAt) > 8 else { return }
        cwdAt = Date()
        let ps = shell("/bin/ps", ["-axo", "pid=,tty=,comm="])
        var pidTTY: [String: String] = [:]             // pid -> /dev/ttysNNN
        for line in ps.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 3, f[1].hasPrefix("ttys") else { continue }
            let comm = f[2...].joined(separator: " ")
            guard comm.hasSuffix("zsh") || comm.hasSuffix("bash") || comm.hasSuffix("fish") else { continue }
            pidTTY[f[0]] = "/dev/" + f[1]
        }
        guard !pidTTY.isEmpty else { return }
        let out = shell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pidTTY.keys.joined(separator: ",")])
        var cur = ""
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { cur = String(line.dropFirst()) }
            else if line.hasPrefix("n"), let tty = pidTTY[cur] {
                map[tty] = String(line.dropFirst())
            }
        }
        if !map.isEmpty { cwdCache = map }
    }

    /// One AppleScript pass over every Terminal tab: gives us the window number for
    /// each tty and the full inventory of windows, Claude or not.
    func refreshTabs(force: Bool = false) {
        guard force || Date().timeIntervalSince(windowMapAt) > 2.5 else { return }
        windowMapAt = Date()
        let script = """
        set AppleScript's text item delimiters to ","
        tell application "Terminal"
          set out to ""
          repeat with w from 1 to count windows
            repeat with t from 1 to count tabs of window w
              set tb to tab t of window w
              set procs to ""
              try
                set procs to (processes of tb) as text
              end try
              set nm to ""
              try
                set nm to custom title of tb
              end try
              set out to out & w & "|" & t & "|" & (tty of tb) & "|" & (busy of tb) & "|" & nm & "|" & procs & linefeed
            end repeat
          end repeat
          return out
        end tell
        """
        refreshCwds()
        let out = shell("/usr/bin/osascript", ["-e", script])
        guard !out.isEmpty else { return }
        var found: [TermTab] = []
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let f = line.components(separatedBy: "|")
            guard f.count >= 6 else { continue }
            let tty = f[2]
            map[tty] = "w" + f[0]
            found.append(TermTab(window: Int(f[0]) ?? 0,
                                 tab: Int(f[1]) ?? 0,
                                 tty: tty,
                                 busy: f[3] == "true",
                                 title: f[4].trimmingCharacters(in: .whitespaces),
                                 procs: f[5].split(separator: ",").map(String.init),
                                 cwd: cwdCache[tty] ?? ""))
        }
        if !map.isEmpty { windowMap = map }
        tabs = found
    }

    func scan() -> [Session] {
        refreshTabs()
        var out: [Session] = []
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir,
                                                      includingPropertiesForKeys: nil) else { return [] }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidNum = obj["pid"] as? NSNumber,
                  let sid = obj["sessionId"] as? String else { continue }
            let pid = pidNum.int32Value
            guard alive(pid) else { continue }
            let t = tty(for: pid)
            var s = Session(
                id: sid,
                pid: pid,
                cwd: obj["cwd"] as? String ?? "",
                name: obj["name"] as? String ?? "",
                status: obj["status"] as? String ?? "",
                waitingFor: obj["waitingFor"] as? String ?? "",
                updatedAt: ((obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                startedAt: ((obj["startedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                tty: t,
                windowLabel: windowMap[t] ?? ""
            )
            if s.updatedAt == 0 { s.updatedAt = s.startedAt }
            out.append(s)
        }
        func rank(_ s: Session) -> Int {
            if s.needsYou { return 0 }
            if s.isWorking { return 1 }
            return 2
        }
        out.sort {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.updatedAt > $1.updatedAt
        }
        return out
    }

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
        if shell("/usr/bin/osascript", ["-e", script]) != "ok" { NSSound.beep() }
    }

    func openTUI() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = """
        tell application "Terminal"
          activate
          do script "\(home)/.local/bin/ccm"
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
    @Published var tick: Date = Date()
    private var timer: Timer?
    private var lastState: [String: String] = [:]     // sessionId -> status
    private var busySince: [String: Date] = [:]

    init() { refresh(); start() }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
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
        DispatchQueue.global(qos: .utility).async {
            let s = Scanner.shared.scan()
            let liveTTYs = Set(s.map { $0.tty })
            let rest = Scanner.shared.tabs
                .filter { !liveTTYs.contains($0.tty) }
                .sorted {
                    let a = ($0.hasClaude ? 0 : ($0.busy ? 1 : 2), $0.window)
                    let b = ($1.hasClaude ? 0 : ($1.busy ? 1 : 2), $1.window)
                    return a < b
                }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.noteTransitions(s)
                    if s != self.sessions { self.sessions = s }
                    if rest != self.others { self.others = rest }
                    self.tick = Date()
                    AppDelegate.shared?.updateStatusItem(self.sessions)
                }
            }
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

    /// Working sessions breathe; a session that needs you blinks harder.
    var pulse: Double {
        if s.needsYou { return 0.35 + 0.65 * abs(sin(now.timeIntervalSince1970 * 3.2)) }
        if s.isWorking { return 0.55 + 0.45 * abs(sin(now.timeIntervalSince1970 * 2)) }
        return 1
    }

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
                .opacity(pulse)
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
    /// True while Terminal (or our own alert) owns the screen.
    var terminalIsFront = false
    var followTerminal: Bool {
        (UserDefaults.standard.object(forKey: "followTerminal") as? Bool) ?? true
    }
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
        let frame = saved.map { NSRectFromString($0) } ?? NSRect(x: 60, y: 60, width: 320, height: 420)

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
        frontAppChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

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
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
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

    func menuWillOpen(_ menu: NSMenu) { refreshLoginItem() }

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
