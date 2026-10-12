#!/usr/bin/env bash
set -u
export LC_ALL=C.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../lib/pulse-lib.sh"

INPUT="$(cat)"
SID="$(jq -r '.session_id // empty' <<<"$INPUT")"
NOW="$(now_ms)"

if [ -n "$SID" ]; then
  ensure_session "$SID" "$INPUT" "$NOW" "statusline"
  update_session "$SID" '
    .model = ($i.model.display_name // .model)
    | .modelId = ($i.model.id // .modelId)
    | .contextPct = ($i.context_window.used_percentage // .contextPct)
    | .contextSize = ($i.context_window.context_window_size // .contextSize)
    | .contextTokens = (if $i.context_window.current_usage != null then
        (($i.context_window.current_usage.input_tokens // 0)
          + ($i.context_window.current_usage.cache_creation_input_tokens // 0)
          + ($i.context_window.current_usage.cache_read_input_tokens // 0))
        else .contextTokens end)
    | .durationMs = ($i.cost.total_duration_ms // .durationMs)
    | .apiDurationMs = ($i.cost.total_api_duration_ms // .apiDurationMs)
    | .costUsd = ($i.cost.total_cost_usd // .costUsd)
    | .sessionName = ($i.session_name // .sessionName)
    | .worktree = ($i.workspace.git_worktree // $i.worktree.name // .worktree)
    | .version = ($i.version // .version)
    | ($i.prompt_cache.expires_at // null) as $e
    | .cacheExpiresAt = (if $e == null then .cacheExpiresAt
        elif ($e | type) == "number" then (if $e < 1e12 then $e * 1000 else $e end)
        else (try (($e | sub("\\.[0-9]+"; "") | fromdateiso8601) * 1000) catch .cacheExpiresAt) end)
    | .metricsSource = "statusline" | .metricsAt = $now
  ' --argjson i "$INPUT" --argjson now "$NOW"
fi

jq -r '
  def dur: if . == null then "–" else (. / 60000 | floor) as $m
    | if $m >= 60 then "\($m / 60 | floor)h \($m % 60)m" else "\($m)m" end end;
  [ (.model.display_name // .model.id // "claude"),
    "ctx \((.context_window.used_percentage // 0) | floor)%",
    (.cost.total_duration_ms | dur),
    (.workspace.git_worktree // .worktree.name // (.cwd // "" | split("/") | last)) ]
  | join(" · ")
' <<<"$INPUT"
