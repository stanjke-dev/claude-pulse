#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
LINK="$HOME/.claude/pulse"
EXT_UUID="claude-pulse@stanjke.dev"
EXT_SRC="$SCRIPT_DIR/ui/gnome/$EXT_UUID"
EXT_DST="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
HOOK_CMD='$HOME/.claude/pulse/reporters/claude-code/pulse-hook.sh'
STATUSLINE_CMD='$HOME/.claude/pulse/reporters/claude-code/pulse-statusline.sh'
EVENTS='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","Notification","SubagentStart","SubagentStop","Stop","SessionEnd","PostModelSwitch"]'

info() { echo -e "\033[1;34m[pulse]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }

for dep in jq python3 flock; do
  command -v "$dep" >/dev/null || { echo "ERROR: $dep is required" >&2; exit 1; }
done

if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "ERROR: $LINK exists and is not a symlink; move it away first" >&2
  exit 1
fi
ln -sfn "$SCRIPT_DIR" "$LINK"
info "linked $LINK -> $SCRIPT_DIR"

mkdir -p "$(dirname "$SETTINGS")"
[ -s "$SETTINGS" ] || echo '{}' >"$SETTINGS"
BACKUP="$SETTINGS.bak-pulse-$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"
info "settings backup: $BACKUP"

jq --arg cmd "$HOOK_CMD" --arg sl "$STATUSLINE_CMD" --argjson events "$EVENTS" '
  def without_pulse: map(select(((.hooks // []) | map(.command // "") | any(test("pulse-hook\\.sh"))) | not));
  .hooks //= {}
  | reduce $events[] as $e (.;
      .hooks[$e] = (((.hooks[$e] // []) | without_pulse) + [{hooks: [{type: "command", command: $cmd, timeout: 10}]}]))
  | .statusLine = (
      if .statusLine == null or ((.statusLine.command // "") | test("pulse-statusline"))
      then {type: "command", command: $sl, refreshInterval: 30}
      else .statusLine end)
' "$SETTINGS" >"$SETTINGS.tmp"
mv -f "$SETTINGS.tmp" "$SETTINGS"
info "hooks registered for: $(jq -r '. | join(", ")' <<<"$EVENTS")"

if ! jq -e '.statusLine.command | test("pulse-statusline")' "$SETTINGS" >/dev/null; then
  warn "a different statusLine is configured; Pulse metrics will fall back to the transcript."
  warn "to chain it, make your statusline script pipe its stdin into $STATUSLINE_CMD as well."
fi

mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/claude-pulse/sessions"

mkdir -p "$HOME/.local/bin"
ln -sfn "$SCRIPT_DIR/bin/pulse" "$HOME/.local/bin/pulse"
info "terminal command: pulse (linked to ~/.local/bin/pulse)"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "~/.local/bin is not on PATH";; esac

if [ "$(uname -s)" = "Linux" ] && [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
  mkdir -p "$(dirname "$EXT_DST")"
  ln -sfn "$EXT_SRC" "$EXT_DST"
  info "linked GNOME extension to $EXT_DST"
  python3 - "$EXT_UUID" <<'PY'
import ast, subprocess, sys
uuid = sys.argv[1]
raw = subprocess.check_output(["gsettings", "get", "org.gnome.shell", "enabled-extensions"]).decode().strip()
if raw.startswith("@as"):
    raw = raw[3:].strip()
current = list(ast.literal_eval(raw)) if raw not in ("[]", "") else []
if uuid not in current:
    current.append(uuid)
    value = "[" + ", ".join(repr(u) for u in current) + "]"
    subprocess.check_call(["gsettings", "set", "org.gnome.shell", "enabled-extensions", value])
    print(f"[pulse] extension {uuid} enabled in gsettings")
else:
    print(f"[pulse] extension {uuid} already enabled")
PY
  if [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
    info "reload GNOME Shell to load the extension: Alt+F2, type r, Enter"
  else
    info "log out and back in to load the extension (Wayland cannot reload the shell)"
  fi
else
  warn "not a GNOME session: the panel renderer is skipped; the reporter still records state in ~/.local/state/claude-pulse"
fi

info "optional: echo '{\"focusKey\": \"ctrl+escape\"}' > ~/.config/claude-pulse/config.json to jump into the Claude input after focusing a window (needs xdotool and a matching VS Code keybinding)"
info "done"
