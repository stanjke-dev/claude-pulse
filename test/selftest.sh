#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_PULSE_STATE_DIR="$(mktemp -d)"
HOOK="$HERE/../reporters/claude-code/pulse-hook.sh"
SL="$HERE/../reporters/claude-code/pulse-statusline.sh"
SID="selftest-$$"
CWD="$HOME"
FILE="$CLAUDE_PULSE_STATE_DIR/sessions/$SID.json"
export XDG_CONFIG_HOME="$CLAUDE_PULSE_STATE_DIR/config"
mkdir -p "$XDG_CONFIG_HOME/claude-pulse" && echo '{"sound": false}' >"$XDG_CONFIG_HOME/claude-pulse/config.json"

fire() { jq -nc --arg sid "$SID" --arg cwd "$CWD" --arg ev "$1" "{session_id: \$sid, cwd: \$cwd, hook_event_name: \$ev} + ($2)" | "$HOOK"; }
expect() { local got; got="$(jq -r "$1" "$FILE")"; if [ "$got" != "$2" ]; then echo "FAIL [$3]: $1 = '$got', expected '$2'"; cat "$FILE"; exit 1; fi; echo "ok   $3"; }

fire SessionStart '{source: "startup", model: "claude-fable-5-1"}'
expect .state idle "SessionStart -> idle"
expect .modelId claude-fable-5-1 "SessionStart records model"
fire UserPromptSubmit '{prompt: "do the thing"}'
expect .state working "prompt -> working"
expect .unseen false "prompt clears unseen"
fire PreToolUse '{tool_name: "Bash", tool_input: {command: "ls"}}'
expect .currentTool Bash "PreToolUse records tool"
fire SubagentStart '{agent_id: "a1", agent_type: "Explore"}'
fire SubagentStart '{agent_id: "a2", agent_type: "Explore"}'
fire SubagentStart '{agent_id: "a2", agent_type: "Explore"}'
expect '.agents | length' 2 "two agents, deduplicated"
fire PreToolUse '{agent_id: "a1", tool_name: "Read", tool_input: {}}'
expect .state working "subagent tool use does not touch state"
fire PreToolUse '{tool_name: "AskUserQuestion", tool_input: {questions: [{question: "Which DB?"}]}}'
expect .state waiting "AskUserQuestion -> waiting"
expect .reason "question: Which DB?" "reason has the question"
fire PostToolUse '{tool_name: "AskUserQuestion", tool_response: {}}'
expect .state working "answer -> working"
fire PermissionRequest '{tool_name: "Bash"}'
expect .state waiting "PermissionRequest -> waiting"
fire Notification '{notification_type: "permission_prompt", message: "Claude needs your permission"}'
expect .state waiting "permission notification keeps waiting"
fire PostToolUse '{tool_name: "Bash", tool_response: {}}'
expect .state working "tool ran -> working"
fire SubagentStop '{agent_id: "a1"}'
expect '.agents | length' 1 "agent stop decrements"
fire Stop '{stop_hook_active: false, last_assistant_message: "All done.\nNext steps…"}'
expect .state done "Stop -> done"
expect .unseen true "Stop marks the result unseen"
expect '.agents | length' 0 "Stop clears agents"
expect .lastMessage "All done. Next steps…" "Stop keeps last message"
fire Notification '{notification_type: "idle_prompt", message: "waiting"}'
expect .state done "idle keeps done"
jq -nc --arg sid "$SID" --arg cwd "$CWD" '{session_id: $sid, cwd: $cwd, model: {id: "claude-fable-5-1", display_name: "Fable 5.1"}, context_window: {context_window_size: 200000, used_percentage: 42.4, current_usage: {input_tokens: 100, cache_creation_input_tokens: 4000, cache_read_input_tokens: 80000}}, cost: {total_duration_ms: 4500000, total_cost_usd: 1.2}, workspace: {git_worktree: "feat-x"}}' | "$SL"
expect .model "Fable 5.1" "statusline sets model"
expect .contextTokens 84100 "statusline sets context tokens"
expect .contextPct 42.4 "statusline sets context pct"
fire UserPromptSubmit '{prompt: "pulse label My Window"}' | jq -e '.decision == "block"' >/dev/null
expect .label "My Window" "pulse label command pins label"
expect .state done "label command does not change state"
fire UserPromptSubmit '{prompt: "pulse unbind"}' | jq -e '.reason | test("removed")' >/dev/null
expect .bound false "pulse unbind"
fire UserPromptSubmit '{prompt: "pulse bind Renamed"}' | jq -e '.reason | test("Renamed")' >/dev/null
expect .bound true "pulse bind"
expect .label Renamed "pulse bind with name relabels"
fire UserPromptSubmit '{prompt: "pulse mode manual"}' | jq -e '.reason | test("manual")' >/dev/null
[ "$(jq -r .mode "$XDG_CONFIG_HOME/claude-pulse/config.json")" = manual ] && echo "ok   pulse mode manual writes config" || { echo "FAIL mode"; exit 1; }
fire UserPromptSubmit '{prompt: "pulse"}' | jq -e '.reason | test("Renamed") and test("done")' >/dev/null && echo "ok   pulse status replies with details"
fire UserPromptSubmit '{prompt: "pulse list"}' | jq -e '.reason | test("Renamed")' >/dev/null && echo "ok   pulse list"
fire UserPromptSubmit '{prompt: "pulse help"}' | jq -e '.reason | test("pulse bind")' >/dev/null && echo "ok   pulse help"
fire UserPromptSubmit '{prompt: "pulse bogus"}' | jq -e '.reason | test("unknown command")' >/dev/null && echo "ok   unknown pulse command"
PULSE_BIN="$HERE/../bin/pulse"
"$PULSE_BIN" list | grep -q "Renamed" && echo "ok   cli list"
"$PULSE_BIN" unbind Renamed >/dev/null && expect .bound false "cli unbind by label"
"$PULSE_BIN" bind "${SID:0:8}" >/dev/null && expect .bound true "cli bind by id prefix"
"$PULSE_BIN" label renamed "Final Name" >/dev/null && expect .label "Final Name" "cli label (case-insensitive match)"
"$PULSE_BIN" mode auto >/dev/null && [ "$("$PULSE_BIN" mode)" = "mode: auto" ] && echo "ok   cli mode"
"$PULSE_BIN" status "Final Name" | grep -q "model: Fable" && echo "ok   cli status" || { "$PULSE_BIN" status "Final Name"; }
SID2="selftest-second-$$"
jq -nc --arg sid "$SID2" --arg cwd "$CWD" '{session_id: $sid, cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: "hello"}' | "$HOOK" >/dev/null
[ "$("$PULSE_BIN" list | grep -c '●')" = 2 ] && echo "ok   two visible sessions" || { "$PULSE_BIN" list; exit 1; }
fire UserPromptSubmit '{prompt: "pulse move last"}' | jq -e '.reason | test("position 2")' >/dev/null && echo "ok   pulse move last"
expect .order 1 "order persisted on session"
"$PULSE_BIN" move "Final Name" first >/dev/null && expect .order 0 "cli move first"
fire UserPromptSubmit '{prompt: "pulse move sideways"}' | jq -e '.reason | test("usage")' >/dev/null && echo "ok   pulse move usage"
fire SessionEnd '{reason: "other"}'
[ ! -e "$FILE" ] && echo "ok   SessionEnd removes file" || { echo "FAIL SessionEnd"; exit 1; }
rm -rf "$CLAUDE_PULSE_STATE_DIR"
echo "ALL OK"
