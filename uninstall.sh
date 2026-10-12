#!/usr/bin/env bash
set -euo pipefail

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
EXT_UUID="claude-pulse@stanjke.dev"

info() { echo -e "\033[1;34m[pulse]\033[0m $*"; }

if [ -s "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-pulse-uninstall-$(date +%Y%m%d-%H%M%S)"
  jq '
    .hooks = ((.hooks // {}) | with_entries(
        .value |= map(select(((.hooks // []) | map(.command // "") | any(test("pulse-hook\\.sh"))) | not))
      ) | with_entries(select(.value | length > 0)))
    | if ((.statusLine.command // "") | test("pulse-statusline")) then del(.statusLine) else . end
    | if .hooks == {} then del(.hooks) else . end
  ' "$SETTINGS" >"$SETTINGS.tmp" && mv -f "$SETTINGS.tmp" "$SETTINGS"
  info "removed Pulse hooks and statusline from $SETTINGS"
fi

gnome-extensions disable "$EXT_UUID" 2>/dev/null || true
rm -f "$HOME/.local/share/gnome-shell/extensions/$EXT_UUID" "$HOME/.local/bin/pulse" "$HOME/.claude/pulse"
info "removed the extension link, the pulse command and ~/.claude/pulse"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/claude-pulse" "${XDG_CONFIG_HOME:-$HOME/.config}/claude-pulse"
  info "removed state and config"
else
  info "state and config kept (rerun with --purge to delete ~/.local/state/claude-pulse and ~/.config/claude-pulse)"
fi
info "reload GNOME Shell (Alt+F2, r) or log out to unload the extension"
