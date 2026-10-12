#!/usr/bin/env bash
set -u
export LC_ALL=C.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../lib/pulse-lib.sh"

INPUT="$(cat)"
EVENT="$(jq -r '.hook_event_name // empty' <<<"$INPUT")"
SID="$(jq -r '.session_id // empty' <<<"$INPUT")"
[ -z "$SID" ] && exit 0
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT")"
TRANSCRIPT="$(jq -r '.transcript_path // empty' <<<"$INPUT")"
NOW="$(now_ms)"

if [ "$EVENT" = "SessionEnd" ]; then
  remove_session "$SID"
  exit 0
fi

ensure_session "$SID" "$INPUT" "$NOW" "$EVENT"

refresh_transcript_metrics() {
  local file src at
  file="$(session_file "$SID")"
  src="$(jq -r '.metricsSource // ""' "$file" 2>/dev/null)"
  at="$(jq -r '.metricsAt // 0' "$file" 2>/dev/null)"
  [ "$src" = "statusline" ] && [ $((NOW - at)) -lt 120000 ] && return 0
  [ "$src" = "transcript" ] && [ $((NOW - at)) -lt 20000 ] && return 0
  local metrics
  metrics="$(transcript_metrics "$TRANSCRIPT")"
  [ "$metrics" = "{}" ] && return 0
  update_session "$SID" '. + $m | .metricsAt = $now' --argjson m "$metrics" --argjson now "$NOW"
}

reply() {
  jq -n --arg r "$1" '{decision: "block", reason: $r}'
}

pulse_command() {
  local args="$1" verb rest
  verb="${args%% *}"
  rest="${args#"$verb"}"; rest="${rest# }"
  case "$verb" in
    bind)
      update_session "$SID" '.bound = true | .hidden = false | if $l != "" then .label = $l | .labelPinned = true else . end' --arg l "$rest"
      reply "Pulse: session bound to the panel as \"$(jq -r '.label // .id' "$(session_file "$SID")")\".";;
    unbind|hide)
      update_session "$SID" '.bound = false | .hidden = true'
      reply "Pulse: session removed from the panel. Type 'pulse bind' to show it again.";;
    show)
      update_session "$SID" '.bound = true | .hidden = false'
      reply "Pulse: session shown on the panel.";;
    label|name|rename)
      [ -z "$rest" ] && { reply "Pulse: usage: pulse label <name>"; return; }
      update_session "$SID" '.label = $l | .labelPinned = true' --arg l "$rest"
      reply "Pulse: indicator labelled \"$rest\".";;
    unlabel)
      update_session "$SID" '.labelPinned = false | .label = .windowHint'
      reply "Pulse: label reset to the VS Code window name.";;
    move|order)
      local pos
      if pos="$(move_session "$SID" "$rest")"; then
        reply "Pulse: this session's dot is now at position $pos."
      elif [ $? -eq 2 ]; then
        reply "Pulse: usage: pulse move left|right|first|last|<n>"
      else
        reply "Pulse: this session is not on the panel (pulse bind first)."
      fi;;
    sound)
      case "$rest" in
        on) config_set '.sound = true'; reply "Pulse: sounds on.";;
        off) config_set '.sound = false'; reply "Pulse: sounds off.";;
        test) play_sound done; reply "Pulse: played the completion sound.";;
        "") reply "Pulse: sounds are $(sound_enabled && echo on || echo off). Use 'pulse sound on|off|test'.";;
        *) reply "Pulse: usage: pulse sound on|off|test";;
      esac;;
    mode)
      case "$rest" in
        auto|manual) config_set '.mode = $m' --arg m "$rest"; reply "Pulse: mode set to $rest ($( [ "$rest" = auto ] && echo 'every session appears automatically' || echo 'only sessions after pulse bind appear')).";;
        "") reply "Pulse: mode is $(pulse_mode). Use 'pulse mode auto' or 'pulse mode manual'.";;
        *) reply "Pulse: unknown mode '$rest'. Use auto or manual.";;
      esac;;
    status|"")
      reply "$(describe_session "$(session_file "$SID")")";;
    list|ls)
      local out="" f
      for f in "$PULSE_SESSIONS_DIR"/*.json; do
        [ -s "$f" ] || continue
        out+="$(describe_session "$f" | head -1)"$'\n'
      done
      reply "Pulse sessions (mode: $(pulse_mode)):"$'\n'"${out:-  none}";;
    help|-h|--help)
      reply "Pulse commands (typed as a prompt, never sent to the model; act on this session):
  pulse                    status: label, state, model, context, time
  pulse bind [name]        show this session on the panel, optionally with a label
  pulse unbind             remove it from the panel
  pulse label <name>       rename the dot;  pulse unlabel  resets it
  pulse move left|right|first|last|<n>   reorder the dot (also: mouse wheel over it)
  pulse list               all tracked sessions
  pulse mode auto|manual   auto = every session appears; manual = only after bind
  pulse sound on|off|test  chimes; pick sounds in a terminal: pulse sound list / play / done / waiting
Dots: green = working (digit = agents), yellow = waiting for you, red = finished, ring = cache cooling.
Mouse: left click = open the session, right click = menu, wheel = reorder.
Full manual with every option: run 'pulse help' in a terminal.";;
    *)
      reply "Pulse: unknown command '$verb'. Try 'pulse help'.";;
  esac
}

set_waiting() {
  local prev
  prev="$(jq -r '.state // ""' "$(session_file "$SID")" 2>/dev/null)"
  update_session "$SID" '.state = "waiting" | .reason = $r | .waitingSince = (.waitingSince // $now)' --arg r "$1" --argjson now "$NOW"
  [ "$prev" != "waiting" ] && play_sound waiting
}

set_working() {
  update_session "$SID" '.state = "working" | .reason = null | .waitingSince = null | .currentTool = $t' --argjson t "${1:-null}"
}

case "$EVENT" in
  SessionStart)
    update_session "$SID" '
      .state = (if .state == null or $source == "clear" then "idle" else .state end)
      | .agents = (if $source == "clear" then [] else .agents end)
      | .modelId = ($model // .modelId)
      | .sessionTitle = ($title // .sessionTitle)
    ' --arg source "$(jq -r '.source // ""' <<<"$INPUT")" \
      --argjson model "$(jq -c '.model // null' <<<"$INPUT")" \
      --argjson title "$(jq -c '.session_title // null' <<<"$INPUT")"
    ;;

  UserPromptSubmit)
    PROMPT="$(jq -r '.prompt // ""' <<<"$INPUT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$PROMPT" =~ ^/?pulse([[:space:]]+(.*))?$ ]]; then
      pulse_command "${BASH_REMATCH[2]:-}"
      exit 0
    fi
    update_session "$SID" '
      .state = "working" | .reason = null | .waitingSince = null | .lastMessage = null | .unseen = false
      | .turnStartedAt = $now | .finishedAt = null | .turns = ((.turns // 0) + 1)
      | .sessionTitle = ($title // .sessionTitle)
    ' --argjson now "$NOW" --argjson title "$(jq -c '.session_title // null' <<<"$INPUT")"
    ;;

  PreToolUse)
    [ -n "$AGENT_ID" ] && exit 0
    TOOL="$(jq -r '.tool_name // ""' <<<"$INPUT")"
    case "$TOOL" in
      AskUserQuestion)
        set_waiting "question: $(jq -r '(.tool_input.questions[0].question // "") | .[0:160]' <<<"$INPUT")";;
      ExitPlanMode)
        set_waiting "plan approval";;
      *)
        set_working "$(jq -c '.tool_name // null' <<<"$INPUT")";;
    esac
    ;;

  PostToolUse|PostToolUseFailure)
    [ -n "$AGENT_ID" ] && exit 0
    set_working null
    refresh_transcript_metrics
    ;;

  PermissionRequest)
    [ -n "$AGENT_ID" ] && exit 0
    set_waiting "permission: $(jq -r '.tool_name // "tool"' <<<"$INPUT")"
    ;;

  Notification)
    TYPE="$(jq -r '.notification_type // ""' <<<"$INPUT")"
    case "$TYPE" in
      permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input)
        set_waiting "$TYPE: $(jq -r '(.message // "") | .[0:160]' <<<"$INPUT")";;
      idle_prompt)
        update_session "$SID" '.state = (if .state == "working" then "done" else .state end)';;
    esac
    ;;

  SubagentStart)
    [ -z "$AGENT_ID" ] && exit 0
    update_session "$SID" '.agents = ((.agents // []) + [$a] | unique)' --arg a "$AGENT_ID"
    ;;

  SubagentStop)
    [ -z "$AGENT_ID" ] && exit 0
    update_session "$SID" '.agents = ((.agents // []) - [$a])' --arg a "$AGENT_ID"
    ;;

  Stop)
    [ -n "$AGENT_ID" ] && exit 0
    MSG="$(jq -r '(.last_assistant_message // "") | gsub("\\s+"; " ") | .[0:300]' <<<"$INPUT")"
    METRICS="$(transcript_metrics "$TRANSCRIPT")"
    update_session "$SID" '
      .state = "done" | .reason = null | .waitingSince = null | .agents = [] | .currentTool = null | .unseen = true
      | .lastMessage = (if $msg == "" then .lastMessage else $msg end)
      | .finishedAt = $now
      | (.metricsSource == "statusline" and (($now - (.metricsAt // 0)) < 120000)) as $fresh
      | . + ($m | if $fresh then del(.contextTokens, .metricsSource) else . end)
      | .metricsAt = (if $fresh then .metricsAt else $now end)
    ' --arg msg "$MSG" --argjson now "$NOW" --argjson m "$METRICS"
    play_sound done
    ;;

  PostModelSwitch)
    update_session "$SID" '.modelId = ($to // .modelId) | .model = null' --argjson to "$(jq -c '.to_model // null' <<<"$INPUT")"
    ;;
esac
exit 0
