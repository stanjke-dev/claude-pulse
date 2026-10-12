#!/usr/bin/env bash

PULSE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSE_ROOT="$(cd "$PULSE_LIB_DIR/.." && pwd)"
PULSE_STATE_DIR="${CLAUDE_PULSE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-pulse}"
PULSE_SESSIONS_DIR="$PULSE_STATE_DIR/sessions"
mkdir -p "$PULSE_SESSIONS_DIR"

PULSE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-pulse"
PULSE_CONFIG="$PULSE_CONFIG_DIR/config.json"

now_ms() { date +%s%3N; }

config_get() {
  [ -s "$PULSE_CONFIG" ] && jq -r "$1 // empty" "$PULSE_CONFIG" 2>/dev/null
}

config_set() {
  mkdir -p "$PULSE_CONFIG_DIR"
  local cur='{}'
  [ -s "$PULSE_CONFIG" ] && cur="$(cat "$PULSE_CONFIG")"
  jq "$@" <<<"$cur" >"$PULSE_CONFIG.tmp" && mv -f "$PULSE_CONFIG.tmp" "$PULSE_CONFIG"
}

pulse_mode() {
  local m; m="$(config_get '.mode')"
  case "$m" in manual) echo manual;; *) echo auto;; esac
}

session_visible() {
  local file="$1" bound
  bound="$(jq -r 'if .bound == true then "yes" elif .bound == false or .hidden == true then "no" else "auto" end' "$file" 2>/dev/null)"
  case "$bound" in
    yes) return 0;;
    no) return 1;;
    *) [ "$(pulse_mode)" = "auto" ];;
  esac
}

visible_sorted_ids() {
  local mode order='[]' files=()
  mode="$(pulse_mode)"
  [ -s "$PULSE_CONFIG" ] && order="$(jq -c '.order // []' "$PULSE_CONFIG")"
  local f
  for f in "$PULSE_SESSIONS_DIR"/*.json; do [ -s "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -eq 0 ] && return 0
  jq -s -r --arg mode "$mode" --argjson order "$order" '
    map(select(.id != null))
    | map(select(if .bound == true then true elif .bound == false or .hidden == true then false else $mode != "manual" end))
    | map(. + {sortKey: (.order // ((.windowHint as $h | $order | index($h)) // 1e15))})
    | sort_by(.sortKey, .startedAt) | .[].id' "${files[@]}" 2>/dev/null
}

move_session() {
  local id="$1" where="$2" ids=() idx=-1 i n target
  mapfile -t ids < <(visible_sorted_ids)
  n="${#ids[@]}"
  for i in "${!ids[@]}"; do [ "${ids[$i]}" = "$id" ] && idx="$i"; done
  [ "$idx" -lt 0 ] && return 1
  case "$where" in
    left|up) target=$((idx - 1));;
    right|down) target=$((idx + 1));;
    first) target=0;;
    last) target=$((n - 1));;
    ''|*[!0-9]*) return 2;;
    *) target=$((where - 1));;
  esac
  [ "$target" -lt 0 ] && target=0
  [ "$target" -ge "$n" ] && target=$((n - 1))
  local moved=("${ids[@]:0:idx}" "${ids[@]:idx+1}")
  ids=("${moved[@]:0:target}" "$id" "${moved[@]:target}")
  local hints=()
  for i in "${!ids[@]}"; do
    update_session "${ids[$i]}" '.order = $i' --argjson i "$i"
    hints+=("$(jq -r '.windowHint // empty' "$(session_file "${ids[$i]}")")")
  done
  config_set '.order = ($h | reduce .[] as $x ([]; if ($x != "" and (index($x) | not)) then . + [$x] else . end))'     --argjson h "$(printf '%s\n' "${hints[@]}" | jq -R . | jq -s .)"
  echo $((target + 1))
}

sound_enabled() {
  [ "$(config_get '.sound')" != "false" ]
}

play_sound() {
  sound_enabled || return 0
  local kind="$1" name
  name="$(config_get ".sounds.$kind")"
  case "$kind" in
    done) name="${name:-complete}";;
    waiting) name="${name:-message}";;
    *) name="${name:-bell}";;
  esac
  [ "$name" = "off" ] && return 0
  local theme
  for theme in /usr/share/sounds/Yaru/stereo /usr/share/sounds/freedesktop/stereo /usr/share/sounds/gnome/default/alerts; do
    [ -f "$theme/$name.oga" ] && name="$theme/$name.oga" && break
    [ -f "$theme/$name.ogg" ] && name="$theme/$name.ogg" && break
  done
  (
    if [ -f "$name" ]; then
      if command -v paplay >/dev/null; then paplay "$name"
      elif command -v afplay >/dev/null; then afplay "$name"
      elif command -v pw-play >/dev/null; then pw-play "$name"; fi
    elif command -v canberra-gtk-play >/dev/null; then canberra-gtk-play -i "$name"
    elif [ -f "/usr/share/sounds/freedesktop/stereo/$name.oga" ] && command -v paplay >/dev/null; then paplay "/usr/share/sounds/freedesktop/stereo/$name.oga"
    elif command -v afplay >/dev/null; then afplay "/System/Library/Sounds/Glass.aiff"
    fi
  ) >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
}

describe_session() {
  jq -r '
    def dur: if . == null then "–" else (. / 60000 | floor) as $m
      | if $m >= 60 then "\($m / 60 | floor)h \($m % 60)m" else "\($m)m" end end;
    def k: if . == null then "?" elif . >= 1000 then "\(. / 1000 | round)k" else "\(.)" end;
    (.label // (.cwd | split("/") | last)) as $label
    | (if .bound == true then "bound" elif .bound == false or .hidden == true then "unbound" else "auto" end) as $bind
    | (.contextPct // (if .contextTokens != null then (.contextTokens * 100 / (.contextSize // 200000)) else null end)) as $pct
    | [ "\($label)  [\(.state)\(if (.agents | length) > 0 then " · \(.agents | length) agents" else "" end)\(if .reason then " · \(.reason)" else "" end)]  (\($bind))",
        "  model: \(.model // .modelId // "?")  ctx: \(if $pct then "\($pct | floor)% (\(.contextTokens | k) / \(.contextSize // 200000 | k))" else "?" end)",
        "  running: \((.durationMs // (($now - .startedAt))) | dur)  window: \(.windowHint // "?")  id: \(.id[0:8])",
        (if .lastMessage then "  last: \(.lastMessage[0:120])" else empty end)
      ] | join("\n")
  ' --argjson now "$(now_ms)" "$1"
}

session_file() { printf '%s/%s.json' "$PULSE_SESSIONS_DIR" "$1"; }

update_session() {
  local id="$1" filter="$2"
  shift 2
  local file lock
  file="$(session_file "$id")"
  lock="$file.lock"
  (
    flock -w 3 9 || exit 0
    local cur='{}'
    [ -s "$file" ] && cur="$(cat "$file")"
    if jq -c "$@" "$filter" <<<"$cur" >"$file.tmp" 2>/dev/null; then
      mv -f "$file.tmp" "$file"
    else
      rm -f "$file.tmp"
    fi
  ) 9>"$lock"
}

remove_session() {
  local file
  file="$(session_file "$1")"
  rm -f "$file" "$file.tmp" "$file.lock"
}

find_claude_pid() {
  local p="$PPID" i cmd argv0
  for i in 1 2 3 4 5 6 7 8; do
    [ -n "$p" ] && [ "$p" -gt 1 ] || return 0
    cmd="$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)"
    argv0="${cmd%% *}"
    case "$(basename -- "$argv0")" in
      claude|claude-code) echo "$p"; return 0;;
    esac
    case "$cmd" in
      *claude-code/cli.js*|*native-binary/claude*) echo "$p"; return 0;;
    esac
    p="$(cut -d')' -f2 "/proc/$p/stat" 2>/dev/null | awk '{print $2}')"
  done
}

resolve_window() {
  python3 -I "$PULSE_ROOT/reporters/claude-code/resolve-window.py" "$1" "$2" 2>/dev/null || echo null
}

project_key_of() {
  case "$1" in
    */projects/*/*) local d; d="${1%/*}"; printf '%s' "${d##*/}";;
    *) printf '';;
  esac
}

ensure_session() {
  local id="$1" input="$2" now="$3" event="$4"
  local file cwd hint='null' pid key
  file="$(session_file "$id")"
  cwd="$(jq -r '.cwd // ""' <<<"$input")"
  key="$(project_key_of "$(jq -r '.transcript_path // ""' <<<"$input")")"
  if [ ! -s "$file" ] || ! jq -e '.windowHint' "$file" >/dev/null 2>&1; then
    hint="$(resolve_window "$cwd" "$key")"
  elif [ "$event" = "SessionStart" ] || [ "$event" = "UserPromptSubmit" ]; then
    hint="$(resolve_window "$cwd" "$key")"
  fi
  pid="$(find_claude_pid)"
  update_session "$id" '
    .id = $id
    | .cwd = (if (.cwd // "") == "" then $cwd else .cwd end)
    | .transcriptPath = ($tp // .transcriptPath)
    | .pid = ($pid // .pid)
    | .startedAt = (.startedAt // $now)
    | .lastEventAt = $now
    | .lastEvent = $ev
    | .agents = (.agents // [])
    | .state = (.state // "idle")
    | .provider = (.provider // "claude-code")
    | .processPattern = (.processPattern // "claude")
    | .reveal = (if (.id | test("^[0-9a-f-]{36}$")) then {command: ["code", "--open-url", ("vscode://anthropic.claude-code/open?session=" + .id)]} else .reveal end)
    | if $hint != null then
        .windowHint = $hint.hint
        | .workspaceFile = $hint.workspaceFile
        | .label = (if .labelPinned == true then .label else $hint.label end)
      else . end
  ' --arg id "$id" --arg cwd "$cwd" \
    --argjson tp "$(jq -c '.transcript_path // null' <<<"$input")" \
    --argjson pid "${pid:-null}" --argjson now "$now" --arg ev "$event" --argjson hint "$hint"
}

transcript_metrics() {
  local path="$1"
  [ -r "$path" ] || { echo '{}'; return; }
  tail -c 600000 "$path" | grep '"type":"assistant"' | tail -1 | jq -c '
    .message as $m | ($m.usage // {}) as $u |
    (($u.cache_creation.ephemeral_5m_input_tokens // 0) > 0
      and ($u.cache_creation.ephemeral_1h_input_tokens // 0) == 0) as $short |
    (if $short then 300000 else 3600000 end) as $ttl |
    ((.timestamp // "") | sub("\\.[0-9]+Z$"; "Z") | try (fromdateiso8601 * 1000) catch null) as $at |
    {
      modelId: $m.model,
      contextTokens: (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)),
      cacheTtlMs: $ttl,
      lastAssistantAt: $at,
      cacheExpiresAt: (if $at != null then $at + $ttl else null end),
      metricsSource: "transcript"
    } | with_entries(select(.value != null))
  ' 2>/dev/null || echo '{}'
}
