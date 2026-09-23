# ccm — Claude Code session organizer for macOS

Two small tools for when you have a dozen Terminal windows and half of them are
running Claude Code:

- **`ccm`** — a terminal TUI listing every live and past session. Jump to the
  window running one, or resume an old one in a fresh window.
- **`CCMonitor`** — a small always-on-top panel plus a menu bar item that shows
  what each session is doing right now, and tells you when one is waiting on you.

Both read Claude Code's own state files. Nothing is instrumented, patched or
scraped from the screen.

## Install

```sh
git clone https://github.com/andrewnakas/ccm.git ~/Documents/ccm
cd ~/Documents/ccm && ./install.sh
```

Requires macOS with Apple Terminal, `swiftc` (Xcode or Command Line Tools) and
Python 3. The installer builds the app into `~/Applications/CCMonitor.app`,
symlinks `ccm` and `ccmon` into `~/.local/bin`, and optionally sets up
auto-start at login and on Terminal launch.

## `ccm` — the terminal organizer

```
  Claude Code sessions                       6 busy · 12 live
    STATE PROJECT                  WHAT                       AGE
  ● busy  skate3 [ios-suspend]     work on getting ios and…    3m
  ● idle  WineOnline [wine-bb]     do those next steps…       14m
  · 8M    RiverWatch2              great work on ledger 55…  2h13
```

| key | action |
| --- | --- |
| `enter` | jump to a live session's Terminal tab, or resume a past one in a new window |
| `t` | resume in a new tab of the front window |
| `f` | resume as a fork (new session id, original untouched) |
| `n` | start a fresh session in that project directory |
| `space` | preview the last messages of a session |
| `/` | filter by project, prompt or session id (`esc` clears) |
| `l` | live sessions only |
| `X` | terminate a live session (asks first) |
| `c` | copy the `claude --resume …` command |
| `r` / `q` | refresh / quit |

`ccm ls` prints the same list non-interactively, with resume commands.

## CCMonitor — the panel

The top section is your live Claude sessions, sorted so anything blocked on you
comes first:

| dot | state | meaning |
| --- | --- | --- |
| pink, blinking | `needs approval` / `asked you` / `wants a goal` / `sandbox ask` | Claude is blocked waiting for you |
| orange, pulsing | `working` | model turn in progress |
| cyan | `running` | running a shell command |
| green | `your turn` | idle — the turn is done |

The bottom section lists every *other* Terminal window, labelled by the
directory its shell sits in, so an idle window is identifiable at a glance.
Windows running `claude` with no session file are flagged separately.

Click any row — Claude session or plain window — and Terminal comes forward with
that exact tab selected.

Menu bar item: `◉3` working, `✦1` in pink when a session needs you (hover for
which one). Its menu has:

- **Show / hide panel**
- **Show only with Terminal** — the panel rides along with Terminal and gets out
  of the way when you switch apps (on by default)
- **Notify when a session needs me** — a notification when a session starts
  waiting on you, or finishes a task longer than 25s, while Terminal is in the
  background
- **Start automatically** — installs/removes the launch agent

`ccmon` launches it, `ccmon quit` stops it, `ccmon rebuild` recompiles after
editing the Swift source, `ccmon log` shows stderr.

## How it works

- **Live sessions**: `~/.claude/sessions/<pid>.json` holds `{pid, sessionId, cwd,
  name, status, waitingFor, updatedAt}`. `status` is one of `busy`, `shell`,
  `idle`, `waiting`; when it is `waiting`, `waitingFor` says why (`dialog open`,
  `input needed`, `goal proposal`, `sandbox request`). Stale files are filtered
  by `kill(pid, 0)`.
- **Past sessions**: `~/.claude/projects/<slug>/<session-id>.jsonl`, with the
  first real user prompt as the label (falling back to a summary record, a slash
  command, or the first assistant reply). Labels are cached by path+mtime+size
  because transcripts reach tens of megabytes.
- **Jumping to a window**: `ps -o tty=` gives a session's tty, and Terminal
  exposes `tty of tab t of window w` over AppleScript — so the right tab is
  matched exactly rather than guessed from a title.
- **Identifying plain windows**: one `ps` pass plus one batched `lsof -d cwd`
  resolves every shell's working directory.

## Linux and Windows

Not yet — but the port is planned rather than hand-waved: see
[PORTING.md](PORTING.md) for what ports for free (all of the session state),
what has to be rebuilt per platform (revealing a session's terminal, the tray
UI), a capability matrix per desktop, and the order of work. Short version:
tmux gives exact tab switching on every OS, X11 and wlroots compositors can
raise the right window, and Windows Terminal cannot currently be told to switch
to an existing tab at all.

## Caveats

- Apple Terminal only (the AppleScript tab model is Terminal's).
- `ccm`'s "new tab" mode uses System Events keystrokes, which needs
  Accessibility permission; without it, it falls back to a new window.
- The app is ad-hoc signed. First notification may ask for permission; if
  denied, notifications fall back to `osascript display notification`.
