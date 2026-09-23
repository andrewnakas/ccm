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
| `R` | restore the sessions from the last snapshot |
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

Each session row shows the CPU its whole process tree is using, and the strip
along the bottom shows system load against your core count plus what Claude is
costing in total:

```
 ● load 33.4 / 8 cores            claude 486% · 6.1 GB
```

The load dot goes orange above 1× cores and red above 2×, with the whole strip
tinted red — on a small machine this is usually the answer to "why is everything
slow": more concurrent sessions than cores. Hover a row's CPU figure for its
memory and process count.

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

## Crash recovery

CCMonitor writes `~/.claude/ccm/snapshot.json` every 30 seconds (previous copy
kept alongside), holding each live session's id, cwd and name, plus the working
directories of your other Terminal windows. `ccm` writes one too, whenever it
runs.

If Terminal dies, CCMonitor dies, or the machine reboots, bring everything back:

```sh
ccm restore          # lists what is missing, asks, then reopens each one
ccm restore --yes    # no prompt
ccm snapshot         # write one right now
```

Each restored session gets its own Terminal window running
`cd <cwd> && claude --resume <id>`, staggered by a second so twelve sessions do
not boot at once. Sessions that are already running are skipped, so restoring
twice is harmless. The same thing lives in the menu bar as **Restore N sessions
from snapshot…**, and if the snapshot holds sessions while none are running,
CCMonitor says so in a notification rather than waiting to be asked.

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
- **Performance**: a single `ps -axo pid=,ppid=,pcpu=,rss=` pass builds the
  process tree, so a session's cost includes every child it spawned; load comes
  from `getloadavg(3)`.
- **Staying cheap**: every source has its own cadence and they all run on one
  serial queue, so a slow pass can never overlap the next tick. Reading session
  JSON is every 2s, `ps` every 6s, `lsof` every 60s, and the AppleScript window
  inventory — which takes 4s once you have 30+ windows — every 25s and *only
  while the panel is on screen*. Measured steady-state cost with the panel open
  and a dozen live sessions: **1.8% of one core**. Only a session that needs you
  animates its dot; ten breathing dots measured 8% of a core on their own, and
  the colour already says "working".

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
