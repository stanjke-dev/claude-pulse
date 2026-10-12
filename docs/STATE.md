# Session state files

Claude Pulse is split in two halves that only share a directory:

```
reporter (any agent/provider)  ──writes──▶  ~/.local/state/claude-pulse/sessions/<id>.json  ◀──watches──  renderer (GNOME extension, CLI)
```

The renderer never talks to Claude Code. To support another agent (Codex CLI, Cursor, OpenCode, a custom script) write a reporter that maintains one JSON file per live session using the schema below. The GNOME extension, the `pulse` CLI, ordering, binding, sounds and the unseen animation all work unchanged.

The directory is `$XDG_STATE_HOME/claude-pulse/sessions` (`~/.local/state/claude-pulse/sessions` by default). Write atomically (temp file + rename). Delete the file when the session ends.

## Schema

| Field | Type | Who sets it | Meaning |
| --- | --- | --- | --- |
| `id` | string | reporter | unique session id; the file is `<id>.json` |
| `provider` | string | reporter | `claude-code`, `codex`, ... (informational) |
| `state` | `working` \| `waiting` \| `done` \| `idle` | reporter | drives the dot color |
| `agents` | string[] | reporter | ids of running subagents; the length is drawn inside a green dot |
| `reason` | string \| null | reporter | shown for `waiting`: what the session waits for |
| `unseen` | bool | reporter sets `true` on finish; renderer clears | `done` + `unseen` = breathing red dot |
| `label` | string | reporter / user | text shown in the tooltip and the CLI |
| `labelPinned` | bool | user commands | the reporter must not overwrite a pinned label |
| `windowHint` | string | reporter | substring of the editor window title used to raise the window and detect focus |
| `cwd` | string | reporter | working directory (fallback for `windowHint`, shown in the tooltip) |
| `pid` | number | reporter | process to watch; when it exits the file is removed by the renderer |
| `processPattern` | string | reporter | regex the process command line must match (guards against PID reuse); omit to skip |
| `reveal.command` | string[] | reporter | executed after the window is raised to reveal this exact session, e.g. an editor URI |
| `launch.command` | string[] | reporter | executed when no window matches `windowHint` (default: `code <workspaceFile or cwd>`) |
| `workspaceFile` | string \| null | reporter | editor workspace file, used by the default launch |
| `model`, `modelId` | string | reporter | display name / id of the model |
| `contextPct`, `contextTokens`, `contextSize` | number | reporter | context window usage (either percentage or tokens + size) |
| `startedAt`, `turnStartedAt`, `finishedAt`, `waitingSince`, `lastEventAt` | ms epoch | reporter | timestamps for the tooltip |
| `durationMs` | number | reporter | total wall time if the provider reports it (else derived from `startedAt`) |
| `cacheExpiresAt`, `cacheTtlMs` | ms epoch, ms | reporter | prompt-cache cooling ring; omit if the provider has no cache |
| `lastMessage` | string | reporter | last assistant text, trimmed |
| `sessionTitle`, `sessionName` | string | reporter | optional human title |
| `bound` | bool \| absent | user commands | `true` always show, `false` never show, absent = follow the mode |
| `hidden` | bool | legacy | same as `bound: false` |
| `order` | number | user commands | manual position on the panel |

Unknown fields are ignored and preserved, so a reporter may store its own bookkeeping.

## Minimal reporter

```bash
STATE=~/.local/state/claude-pulse/sessions
mkdir -p "$STATE"
jq -n --arg id "$SESSION" --arg cwd "$PWD" --argjson pid "$$" '{
  id: $id, provider: "my-agent", state: "working", agents: [], cwd: $cwd, pid: $pid,
  processPattern: "my-agent", windowHint: ($cwd | split("/") | last),
  startedAt: (now * 1000 | floor), lastEventAt: (now * 1000 | floor)
}' > "$STATE/$SESSION.json.tmp" && mv "$STATE/$SESSION.json.tmp" "$STATE/$SESSION.json"
```

Then update `state` on each transition (`working` → `waiting` → `done`, set `unseen: true` with `done`) and remove the file on exit.

## Config

`~/.config/claude-pulse/config.json`, shared by every reporter and renderer:

```json
{
  "mode": "auto",
  "order": ["workspace-a", "workspace-b"],
  "focusKey": "ctrl+escape",
  "sound": true,
  "sounds": {"done": "message-new-instant", "waiting": "message"}
}
```
