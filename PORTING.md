# Porting plan — Linux and Windows sister apps

`ccm` and `CCMonitor` are macOS-only today, but almost nothing about them is
actually macOS-specific. This document separates what ports for free from what
has to be rebuilt per platform, and proposes an order of work with acceptance
criteria.

Status: **plan, not yet started.** Written 23 Sep 2026 against Claude Code
2.1.280.

---

## 1. What the tools actually depend on

Three layers, in decreasing order of portability.

### Layer 1 — session state (fully portable)

Everything either tool knows comes from files Claude Code already writes:

| what | where | notes |
| --- | --- | --- |
| live sessions | `~/.claude/sessions/<pid>.json` | `pid`, `sessionId`, `cwd`, `name`, `status`, `waitingFor`, `updatedAt`, `startedAt`, `version`, `messagingSocketPath`, `pidDomain` |
| past sessions | `~/.claude/projects/<slug>/<session-id>.jsonl` | slug is the cwd with separators replaced; mtime is last activity |
| session status | `status` field | `busy` \| `shell` \| `idle` \| `waiting` |
| why it is blocked | `waitingFor` field | `dialog open` \| `input needed` \| `goal proposal` \| `sandbox request` |

Two useful hints that this layer is already platform-aware: sessions carry a
`pidDomain` field (`darwin` on macOS), and `messagingSocketPath`
(`/tmp/cc-socks/<pid>.sock` on macOS) — both imply per-platform variants worth
checking rather than assuming.

**Ports for free**, modulo path roots (`%USERPROFILE%\.claude` on Windows) and
liveness checks (`kill(pid, 0)` on POSIX; `OpenProcess`/`Get-Process` on
Windows).

### Layer 2 — "reveal this session" (per platform, the hard part)

macOS works because Terminal.app exposes `tty of tab t of window w` over
AppleScript, so a session's tty — from `ps -o tty=` — identifies its tab
exactly. No other platform has that same one-call answer, so this becomes a
strategy interface with graceful degradation.

### Layer 3 — the panel and tray UI (per platform, rewrite)

AppKit `NSPanel` + `NSStatusItem` + `UNUserNotificationCenter` have direct
equivalents everywhere, but no shared code.

---

## 2. Reveal strategies, best first

The port should try these in order and use the first that applies, rather than
picking one per OS. Ranked by how exactly they land you where you want to be.

1. **tmux / screen — exact, and platform-independent.** If the session runs
   inside tmux, `tmux switch-client -t <session>` + `select-window`/
   `select-pane` lands on the exact pane, on macOS, Linux and WSL alike.
   Detect it from the Claude process's environment (`TMUX`, `TMUX_PANE`):
   `/proc/<pid>/environ` on Linux, `ps eww <pid>` on macOS, WMI or
   `NtQueryInformationProcess` on Windows. **This is the single highest-value
   strategy to build first** — it is exact, testable in CI, and covers the
   users most likely to have a dozen sessions open.
2. **Terminal emulators with a control CLI — exact.** `wezterm cli list
   --format json` returns panes with pid and tty; `kitty @ ls` the same;
   iTerm2 is AppleScript-addressable by tty like Terminal.app. These give
   tab-level precision without any window-manager involvement, on every OS
   those emulators run on.
3. **Linux X11 — window level.** Walk the process tree from the Claude pid up
   to the terminal emulator process, then match `_NET_WM_PID` and activate with
   `wmctrl -i -a <id>` or `xdotool windowactivate`. Tabs inside a
   gnome-terminal/konsole window are not addressable this way; you land on the
   window and the user picks the tab.
4. **Linux Wayland — compositor dependent.** wlroots compositors have IPC that
   takes a pid directly: `swaymsg '[pid=<n>] focus'`, `hyprctl dispatch
   focuswindow pid:<n>`. GNOME and KDE under Wayland have no general window
   activation API — that needs a shell extension, so those sessions degrade to
   strategy 6.
5. **Windows — window level, with a documented gap.** `wt.exe -w <id>
   focus-tab -t <index>` does exist, but Windows Terminal currently offers no
   way to enumerate tabs, query the selected one, or map a `WT_SESSION` to a
   tab index (microsoft/terminal [#18692], [#19783]). So: focus the
   `WindowsTerminal.exe` window with `SetForegroundWindow`, and get exact
   placement only for legacy conhost windows (one window per console) or via
   strategy 1 inside WSL. Do not promise tab switching on Windows Terminal
   until those issues land.
6. **Fallback everywhere — no jump.** Show the session, copy
   `claude --resume <id>` to the clipboard, and raise a notification. This is
   what GNOME/KDE Wayland and multi-tab Windows Terminal get, and it must be a
   first-class path, not an error.

### Capability matrix (target state)

| platform / setup | list + status | needs-you alerts | jump to window | jump to exact tab |
| --- | --- | --- | --- | --- |
| macOS Terminal.app | ✅ done | ✅ done | ✅ done | ✅ done |
| any OS + tmux | ✅ | ✅ | ✅ | ✅ |
| WezTerm / kitty / iTerm2 | ✅ | ✅ | ✅ | ✅ |
| Linux X11 (GNOME, KDE, i3…) | ✅ | ✅ | ✅ | tmux/emulator only |
| Linux Wayland sway / Hyprland | ✅ | ✅ | ✅ | tmux/emulator only |
| Linux Wayland GNOME / KDE | ✅ | ✅ | ❌ (extension needed) | tmux/emulator only |
| Windows Terminal | ✅ | ✅ | ✅ | ❌ (upstream gap) |
| Windows conhost | ✅ | ✅ | ✅ | ✅ (1 tab per window) |
| WSL + Windows Terminal | ✅ | ✅ | ✅ | tmux only |

---

## 3. Work plan

### M0 — extract the spec (no code)
Write `docs/session-state.md` describing layer 1 precisely, including how to
re-verify the `status`/`waitingFor` enums after a Claude Code update:

```sh
grep -ao 'status:"[a-z]*"' ~/.local/share/claude/versions/<ver> | sort -u
grep -ao 'waitingFor:"[a-z ]*"' ~/.local/share/claude/versions/<ver> | sort -u
```

Ship a `tools/fake-sessions.py` that writes synthetic `~/.claude/sessions/*.json`
in every state, so ports can be developed and demoed without running twelve real
Claude sessions. **Done when** a contributor on Linux can see a populated UI
within a minute of cloning.

### M1 — make `ccm` (the TUI) cross-platform
The TUI is stdlib Python and nearly portable already. Restructure the single
file into `ccm/core.py` (scanning, titles, cache), `ccm/reveal/` (strategies),
`ccm/tui.py`.

- Replace POSIX assumptions: `os.kill(pid, 0)`, `/dev/ttys*`, `ps`, `lsof`.
- Windows needs `windows-curses`, or a non-curses fallback renderer.
- Implement reveal strategies 1, 2 and 6 here — they are pure subprocess work
  and carry most of the value.

**Done when** `ccm` lists and resumes sessions on Linux and Windows, and jumps
exactly under tmux on both.

### M2 — Linux window reveal
Strategies 3 and 4: process-tree walk to the emulator pid, `_NET_WM_PID`
matching, sway/Hyprland IPC. Detect the session type from
`XDG_SESSION_TYPE`/`WAYLAND_DISPLAY` and pick accordingly.

**Done when** clicking a session on X11/GNOME and on sway raises the right
terminal window; GNOME Wayland falls back cleanly with a visible explanation.

### M3 — Windows reveal
Process-tree walk to `WindowsTerminal.exe`/`conhost.exe`, `SetForegroundWindow`,
plus `wt -w … focus-tab` where a tab index is actually known (sessions this tool
launched itself). Read the Claude process environment for `WT_SESSION`/`TMUX` via
WMI.

**Done when** clicking a session brings the hosting terminal window forward, and
the known-gap case says so instead of silently doing nothing.

### M4 — the GUI sister apps
Same shape as CCMonitor: a small always-on-top panel, a tray indicator carrying
the needs-you count, notifications on transitions, click to reveal.

Two viable stacks — recommendation first:

| option | pros | cons |
| --- | --- | --- |
| **PySide6 (Qt) for Linux + Windows — recommended** | one GUI codebase for both; reuses the Python core from M1 directly; `QSystemTrayIcon` + `Qt.WindowStaysOnTopHint` work on both; mature notifications | ~60 MB dependency; tray on GNOME Wayland needs the AppIndicator extension |
| Rust (`egui` + `tray-icon` + `notify-rust`) | one static binary, no runtime deps, tiny memory | reimplements the core in a third language; three languages to maintain across the repo |

Native alternatives (GTK4/libadwaita via PyGObject on Linux, WinUI 3 or WPF on
Windows) look and feel best per platform but triple the GUI surface area; worth
it only if the Qt version proves unidiomatic in practice.

**Done when** a Linux and a Windows user each get a panel + tray item that
blinks when a session is `waiting`, and a notification when Claude needs them
while the terminal is in the background.

### M5 — packaging
Linux: a `pipx`-installable package plus a `.desktop` autostart entry (the
equivalent of the launchd agent). Windows: a scheduled task or `shell:startup`
shortcut, and a signed-or-documented binary. Keep `install.sh` as the macOS
path and add `install.ps1` / `install-linux.sh`.

---

## 4. Open questions to settle before M1

These need a machine of each kind; each is a ten-minute check.

1. **Does Claude Code on Windows write `%USERPROFILE%\.claude\sessions\<pid>.json`
   at all, and what is `pidDomain` there?** The whole plan rests on it. Same
   question for native Linux (expected: `linux`, path unchanged).
2. **What is `messagingSocketPath` on Windows?** If it is a named pipe, there
   may be a supported way to talk to a session directly — `peerFeatures`
   already advertises `notify_idle` and `reply_across_default_dirs`, which
   suggests a future where the monitor can answer a session rather than only
   point at it. Worth a spike before designing the UI.
3. **WSL path duality.** A session started inside WSL writes to the Linux home;
   a Windows-native session writes to the Windows home. A Windows monitor
   probably has to read both (`\\wsl$\<distro>\home\<user>\.claude`) and label
   which world each session lives in.
4. **Does `pidDomain` ever disagree with the host reading the file?** That is
   the signal for "this session belongs to another namespace (WSL, container,
   remote)" and should drive whether a reveal is even attempted.

## 5. Non-goals

- Reimplementing the macOS app in a cross-platform toolkit. It works, it is
  native, and rewriting it buys nothing for the ports.
- Scraping terminal scrollback to infer state. `status` + `waitingFor` are
  authoritative; screen scraping would be fragile and slow.
- Managing sessions the user did not start (no auto-answering prompts).

[#18692]: https://github.com/microsoft/terminal/issues/18692
[#19783]: https://github.com/microsoft/terminal/issues/19783
