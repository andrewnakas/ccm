#!/bin/sh
# Install ccm (terminal organizer) + CCMonitor (menu bar panel) for the current user.
set -e
REPO=$(cd "$(dirname "$0")" && pwd)
APP="$HOME/Applications/CCMonitor.app"
BIN="$HOME/.local/bin"

echo "==> building CCMonitor"
swiftc -O -parse-as-library "$REPO/CCMonitor/CCMonitor.swift" -o "$REPO/CCMonitor/CCMonitor"

echo "==> installing app bundle -> $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/CCMonitor/CCMonitor" "$APP/Contents/MacOS/CCMonitor"
cp "$REPO/CCMonitor/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo "==> installing ccm + ccmon -> $BIN"
mkdir -p "$BIN"
ln -sf "$REPO/bin/ccm" "$BIN/ccm"
ln -sf "$REPO/bin/ccmon" "$BIN/ccmon"

printf '==> start CCMonitor at login? [y/N] '
read ans
case "$ans" in
  y|Y)
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s#__HOME__#$HOME#g" "$REPO/LaunchAgents/local.nakas.ccmonitor.plist.template" \
      > "$HOME/Library/LaunchAgents/local.nakas.ccmonitor.plist"
    launchctl bootout "gui/$(id -u)/local.nakas.ccmonitor" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.nakas.ccmonitor.plist"
    echo "   launch agent installed"
    ;;
  *) echo "   skipped (the menu bar item has a 'Start automatically' toggle)" ;;
esac

printf '==> also launch it whenever a Terminal opens (appends to ~/.zshrc)? [y/N] '
read ans2
case "$ans2" in
  y|Y)
    if ! grep -q "CCMonitor" "$HOME/.zshrc" 2>/dev/null; then
      cat >> "$HOME/.zshrc" <<'HOOK'

# CCMonitor — Claude session monitor: make sure it is running whenever a Terminal is open
if [[ -o interactive ]] && [[ -d "$HOME/Applications/CCMonitor.app" ]]; then
  if ! /usr/bin/pgrep -qf "CCMonitor.app/Contents/MacOS/CCMonitor"; then
    /usr/bin/open -g -a "$HOME/Applications/CCMonitor.app" 2>/dev/null
  fi
fi
HOOK
      echo "   hook added to ~/.zshrc"
    else
      echo "   hook already present"
    fi
    ;;
  *) echo "   skipped" ;;
esac

open "$APP" || true
echo "==> done. Run 'ccm' for the terminal organizer."
