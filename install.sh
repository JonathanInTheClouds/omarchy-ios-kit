#!/usr/bin/env bash
# Install (or update) omarchy-ios-kit: the ios-run tools, hot reload, VS Code
# templates and agent instructions, on top of omarchy-apple-dev.
#
#   ./install.sh            interactive: asks for your settings and before
#                           every change outside the kit's own files
#   ./install.sh --yes      accept every optional step (still asks settings
#                           that have no saved value)
#   ./install.sh --no-system  skip the steps that need sudo
#
# Safe to run again (updates in place; your settings are kept). See README.md.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
SHARE="$HOME/.local/share/ios-run"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ios-run"
CONFIG="$CONFIG_DIR/config"
yes=0 system=1
for arg in "$@"; do
  case "$arg" in
    --yes) yes=1 ;;
    --no-system) system=0 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n== %s\n' "$*"; }
ask() { # ask "question" -> 0 for yes
  [ "$yes" = 1 ] && { echo "   $1 [yes: --yes]"; return 0; }
  local reply
  read -r -p "   $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}

# --- 1. Prerequisites -------------------------------------------------------
say "Checking the prerequisites (README: 'Install the toolchain')"
missing=0
check() { if eval "$2" >/dev/null 2>&1; then echo "   ok      $1"; else echo "   MISSING $1"; missing=1; fi; }
check "xtool (~/.local/bin/xtool)" '[ -x "$HOME/.local/bin/xtool" ]'
check "Swift toolchain (swift)" 'command -v swift'
check "iOS SDK registered (swift sdk list: darwin)" 'swift sdk list | grep -qx darwin'
check "pymobiledevice3 (~/pymobile3-venv)" '[ -x "$HOME/pymobile3-venv/bin/pymobiledevice3" ]'
check "inotifywait (inotify-tools, for hot reload)" 'command -v inotifywait'
check "python3 at /usr/bin/python3" '[ -x /usr/bin/python3 ]'
if [ "$missing" = 1 ]; then
  echo
  echo "   Install omarchy-apple-dev first (README section 2), and inotify-tools"
  echo "   (sudo pacman -S inotify-tools). The kit is installed anyway; the tools"
  echo "   will work once those are in place."
fi

# --- 2. Settings ------------------------------------------------------------
say "Your settings ($CONFIG)"
BUNDLE_PREFIX="" APPS_DIR="" APPLE_DEV_REPO="" XCODE_DIR=""
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"
setting() { # setting VAR "question" default
  local var=$1 question=$2 default=$3 current reply
  current=${!var:-$default}
  if [ "$yes" = 1 ] && [ -n "${!var:-}" ]; then
    echo "   $var=$current"
  else
    read -r -p "   $question [$current] " reply
    printf -v "$var" '%s' "${reply:-$current}"
  fi
}
setting BUNDLE_PREFIX "Bundle ID prefix for new apps (reverse domain you control, e.g. com.yourname)" "${BUNDLE_PREFIX:-com.example}"
if ! [[ "$BUNDLE_PREFIX" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "   '$BUNDLE_PREFIX' doesn't look like a reverse domain; fix it later in $CONFIG" >&2
fi
setting APPS_DIR "Folder for your iOS apps" "${APPS_DIR:-$HOME/Projects/ios}"
setting APPLE_DEV_REPO "Where omarchy-apple-dev is cloned" "${APPLE_DEV_REPO:-$HOME/Tools/omarchy-apple-dev}"
setting XCODE_DIR "Where you keep Xcode .xip downloads (only used in upgrade hints)" "${XCODE_DIR:-$HOME/Downloads}"
mkdir -p "$CONFIG_DIR"
cat >"$CONFIG" <<EOF
# omarchy-ios-kit settings (written by install.sh; edit freely).
BUNDLE_PREFIX="$BUNDLE_PREFIX"
APPS_DIR="$APPS_DIR"
APPLE_DEV_REPO="$APPLE_DEV_REPO"
XCODE_DIR="$XCODE_DIR"
EOF
echo "   saved"
[ -d "$APPLE_DEV_REPO" ] || echo "   note: $APPLE_DEV_REPO doesn't exist (yet)"

# --- 3. The kit's own files -------------------------------------------------
say "Installing the tools to $BIN and $SHARE"
mkdir -p "$BIN" "$SHARE"
for f in ios-run new-ios-app ios-toolchain-upgrade; do
  install -m 755 "$KIT/bin/$f" "$BIN/$f"
done
ln -sfn ios-run "$BIN/ios-run-dev"
for d in hot-reload templates vscode tools; do
  mkdir -p "$SHARE/$d"
  # Copy the kit's files over (your own extra files in these folders stay).
  (cd "$KIT/share/$d" && find . -type f -not -path '*/.build/*' -not -name '*.pyc') | while read -r f; do
    install -D -m "$( [ -x "$KIT/share/$d/$f" ] && echo 755 || echo 644)" "$KIT/share/$d/$f" "$SHARE/$d/$f"
  done
done
mkdir -p "$SHARE/docs"
install -m 644 "$KIT/README.md" "$SHARE/docs/README.md"
install -m 644 "$KIT/docs/HOW-IT-WORKS.md" "$SHARE/docs/HOW-IT-WORKS.md"
echo "   ios-run, ios-run-dev, new-ios-app, ios-toolchain-upgrade; hot reload, templates, docs"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "   note: add $BIN to your PATH" ;; esac

# --- 4. Optional: system fixes (sudo) --------------------------------------
if [ "$system" = 1 ]; then
  say "Optional system fixes (each needs sudo; README explains why)"
  if grep -qE '^\s*IgnorePkg\s*=.*\bswift-bin\b' /etc/pacman.conf 2>/dev/null; then
    echo "   ok      swift-bin is already held in /etc/pacman.conf"
  elif ask "Hold swift-bin in /etc/pacman.conf (IgnorePkg), so a routine update can't break the Swift/Xcode SDK match?"; then
    if grep -qE '^\s*IgnorePkg\s*=' /etc/pacman.conf; then
      sudo sed -i -E '0,/^\s*IgnorePkg\s*=/{s/^(\s*IgnorePkg\s*=.*)$/\1 swift-bin/}' /etc/pacman.conf
    else
      sudo sed -i '/^HoldPkg/a IgnorePkg   = swift-bin' /etc/pacman.conf
    fi
    grep -E '^\s*IgnorePkg' /etc/pacman.conf | sed 's/^/   now: /'
  fi
  dropin=/etc/systemd/system/usbmuxd.service.d/restart.conf
  if [ -f "$dropin" ]; then
    echo "   ok      usbmuxd auto-restart is already set up"
  elif ask "Make usbmuxd restart by itself when it crashes (it can abort around debug sessions)?"; then
    sudo install -D -m 644 "$KIT/extras/usbmuxd-restart.conf" "$dropin"
    sudo systemctl daemon-reload
    echo "   installed $dropin"
  fi
  if [ -x "$BIN/ios-toolchain-upgrade" ] && command -v swift >/dev/null; then
    if ! "$BIN/ios-toolchain-upgrade" 2>/dev/null | grep -qE "NEEDED|missing:"; then
      echo "   ok      xcspec patches are in place"
    elif ask "Apply the three xcspec patches swift-bin needs for .strings files (ios-toolchain-upgrade --patch)?"; then
      "$BIN/ios-toolchain-upgrade" --patch
    fi
  fi
fi

# --- 5. Optional: VS Code shortcuts ----------------------------------------
KB="$HOME/.config/Code/User/keybindings.json"
say "Optional VS Code shortcuts (F6 run, Ctrl+Alt+D debug; README 'Shortcuts')"
if ask "Add them to $KB (your existing shortcuts are kept; a backup is made)?"; then
  mkdir -p "$(dirname "$KB")"
  /usr/bin/python3 - "$KB" "$KIT/extras/vscode-keybindings.json" <<'PY'
import json, os, re, shutil, sys, time
target, snippet = sys.argv[1], sys.argv[2]
strip = lambda t: re.sub(r'^\s*//.*$', '', t, flags=re.M)
new = json.loads(strip(open(snippet).read()))
text = open(target).read() if os.path.exists(target) else "[\n]\n"
current = json.loads(strip(text) or "[]")
missing = [e for e in new if not any(e.get("key") == c.get("key") and e.get("command") == c.get("command") and e.get("when") == c.get("when") for c in current)]
if not missing:
    print("   ok      already there"); sys.exit(0)
if os.path.exists(target):
    shutil.copy(target, f"{target}.before-ios-kit.{int(time.time())}")
# Append before the closing bracket, keeping the user's comments and layout.
body = text.rstrip()
assert body.endswith("]"), "keybindings.json doesn't end with ]: add the entries by hand"
inner = body[:-1].rstrip()
sep = "," if inner.rstrip().endswith("}") else ""
add = ",\n".join("    " + json.dumps(e, indent=4).replace("\n", "\n    ") for e in missing)
open(target, "w").write(f"{inner}{sep}\n    // omarchy-ios-kit (see its README)\n{add}\n]\n")
print(f"   added {len(missing)} shortcut(s)")
PY
fi

# --- 6. Optional: Omarchy SUPER+R / SUPER+SHIFT+R ---------------------------
HB="$HOME/.config/hypr/bindings.lua"
if [ -f "$HB" ] && command -v hyprctl >/dev/null; then
  say "Optional Omarchy keys: SUPER+R run, SUPER+SHIFT+R debug (in VS Code)"
  if grep -q "omarchy-ios-kit keys" "$HB"; then
    echo "   ok      already in $HB"
  elif grep -E '"SUPER \+ (SHIFT \+ )?R"' "$HB" | grep -qvE '^[[:space:]]*--'; then
    echo "   skipped: $HB already binds SUPER+R or SUPER+SHIFT+R. Merge"
    echo "            $KIT/extras/hyprland-ios-keys.lua by hand if you want them."
  elif ask "Append the key block to $HB (remove the marked block to undo)?"; then
    cp "$HB" "$HB.before-ios-kit.$(date +%s)"
    { echo; cat "$KIT/extras/hyprland-ios-keys.lua"; } >>"$HB"
    hyprctl reload >/dev/null && echo "   added; Hyprland reloaded"
  fi
fi

# --- 7. Optional: tell your coding agents where the docs are ----------------
say "Optional: point your coding agents at the docs (machine-wide)"
block="<!-- omarchy-ios-kit -->
- iOS development on this machine (xtool, ios-run, VS Code debugging, hot
  reload) is documented in \`~/.local/share/ios-run/docs/\` (README.md,
  HOW-IT-WORKS.md). Apps in \`$APPS_DIR\` each have an AGENTS.md with their
  rules: every SwiftUI view needs \`@ObserveHotReload\` and \`.hotReloadable()\`.
<!-- /omarchy-ios-kit -->"
for f in "$HOME/.claude/CLAUDE.md:Claude Code" "$HOME/.codex/AGENTS.md:Codex"; do
  file=${f%%:*} agent=${f#*:}
  [ -d "$(dirname "$file")" ] || continue
  if grep -q "omarchy-ios-kit" "$file" 2>/dev/null; then
    echo "   ok      $agent ($file)"
  elif ask "Add a short pointer for $agent to $file?"; then
    printf '\n%s\n' "$block" >>"$file"
    echo "   added to $file"
  fi
done

# --- 8. Hot reload signing identity ----------------------------------------
say "Hot reload signing identity"
if [ -f "$HOME/.config/omarchy-apple-dev/development/key.pem" ]; then
  echo "   ok      ~/.config/omarchy-apple-dev/development has key.pem and cert.der"
else
  echo "   Hot reload signs each swap with your development certificate. Once"
  echo "   you've signed in with xtool and installed an app, run:"
  echo "     $SHARE/hot-reload/extract-dev-identity.py"
  echo "   (it copies xtool's certificate and key to an owner-only folder)."
fi

say "Done. Next: README section 'Your first app' (new-ios-app MyApp)."
