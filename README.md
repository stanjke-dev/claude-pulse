# Claude Pulse

<img src="assets/icon.svg" width="96" align="right" alt="Claude Pulse icon">

Top-bar indicator for running several AI coding sessions in parallel. One dot per live session, so you notice the window that is waiting for you or has finished while you work in another one.

Built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in VS Code on Ubuntu/GNOME. The core is provider-neutral: any agent that writes the small JSON state file described in [docs/STATE.md](docs/STATE.md) gets the same dots, tooltip, click-to-focus, ordering and sounds.

| Dot | Meaning |
| --- | --- |
| green | the agent is working; a digit inside is the number of running subagents |
| yellow | blocked on you: a question, a permission prompt, a plan approval |
| red | the turn is finished, nothing runs and nothing is asked |
| red, breathing | finished and you have not looked at it yet |
| grey | the session is open, no prompt sent yet |
| fading ring | prompt cache cooling down (1h or 5m TTL); no ring = cache cold |

- **Hover** a dot: label, state, model, context usage, running time, cache state, last assistant message.
- **Left click**: raise the VS Code window and reveal that exact session tab (two sessions in one window each get their own dot), then press your focus key.
- **Right click**: Open in VS Code · Move left / right · Unbind · Manual mode switch.
- **Mouse wheel** over a dot: move it left or right.
- **Sounds**: a short chime when a session finishes and when it starts waiting for you.

## How it runs

There is no daemon and nothing to start at login.

```
Claude Code ──hooks + statusline──▶ reporters/claude-code/*.sh ──▶ ~/.local/state/claude-pulse/sessions/<id>.json
                                                                        ▲
GNOME Shell extension (loads with the shell) ───watches the directory───┘      bin/pulse (CLI) reads the same files
```

Claude Code runs the reporter on every hook event (prompt, tool call, subagent start/stop, permission request, stop, session end). The reporter rewrites one JSON file per session. The GNOME extension watches that directory with inotify and redraws. The `pulse` command reads and edits the same files.

## Requirements

- Ubuntu 24.04+ / GNOME Shell 45–49 (X11 or Wayland). Other desktops get the reporter and the CLI but no panel.
- `jq`, `python3`, `flock` (util-linux). Optional: `xdotool` for the focus key (X11), `canberra-gtk-play` or `paplay` for sounds, `wmctrl`.
- Claude Code ≥ 2.1 (hooks: `SubagentStart/Stop`, `PermissionRequest`, `Notification`).
- VS Code with the Claude Code extension, for click-to-session.

## Install

```bash
git clone https://github.com/stanjke-dev/claude-pulse.git ~/claude-pulse
cd ~/claude-pulse
bash install.sh          # or: make install
```

`install.sh`:

1. links the repo to `~/.claude/pulse` and `bin/pulse` to `~/.local/bin/pulse`;
2. backs up `~/.claude/settings.json` and registers the reporter on 12 hook events plus `statusLine` (an existing custom statusline is left alone, with a warning);
3. links the GNOME extension into `~/.local/share/gnome-shell/extensions/` and enables it.

Then reload GNOME Shell: on X11 press `Alt+F2`, type `r`, Enter; on Wayland log out and back in. Open a Claude Code session and the first dot appears. The installer is idempotent; rerun it after `git pull`.

To jump straight into the Claude input after a click, bind a VS Code shortcut to **Claude Code: Focus Input** (the extension's default is `ctrl+escape`) and tell Pulse to press it:

```bash
mkdir -p ~/.config/claude-pulse && echo '{"focusKey": "ctrl+escape"}' > ~/.config/claude-pulse/config.json
```

Uninstall with `bash uninstall.sh` (`--purge` also deletes state and config).

## Usage

### In a Claude chat

Type these as a normal prompt. The hook intercepts them, replies in a notice, and the model never sees them. They act on the session you type them in.

| Command | Effect |
| --- | --- |
| `pulse` | this session's status |
| `pulse bind [name]` | show this session on the panel, optionally with a label |
| `pulse unbind` | remove it from the panel until the next `pulse bind` |
| `pulse label <name>` / `pulse unlabel` | rename the dot / reset to the VS Code window name |
| `pulse move left\|right\|first\|last\|<n>` | reorder the dot |
| `pulse list` | every tracked session |
| `pulse mode auto\|manual` | auto: every session appears; manual: only after `pulse bind` |
| `pulse sound on\|off\|test` | chimes |
| `pulse help` | the list above |

### In a terminal

`pulse help` prints the full manual. Sessions are addressed by label (case-insensitive), window name or id prefix.

```bash
pulse list
pulse status my-feature
pulse focus my-feature                 # raise the window, reveal the session tab
pulse bind 8655 "Billing refactor"
pulse unbind my-feature
pulse move my-feature left
pulse mode manual
pulse sound list                   # system sound names
pulse sound play swing             # audition
pulse sound done message-new-instant
pulse sound waiting dialog-question
pulse prune                        # drop files of dead processes
```

### Ordering

Order is manual, nothing is auto-detected: wheel over a dot, the right-click menu, or `pulse move`. The position sticks to the session and to its VS Code workspace, so a new session in the same window appears in the same place.

### Modes

`auto` (default) shows every session as soon as it does anything. `manual` shows only sessions you `pulse bind`. Switch in chat, in the terminal, or with the switch in a dot's menu.

## Configuration

`~/.config/claude-pulse/config.json`:

```json
{
  "mode": "auto",
  "order": ["frontend", "backend"],
  "focusKey": "ctrl+escape",
  "sound": true,
  "sounds": {"done": "message-new-instant", "waiting": "message"}
}
```

Sound values are names from the system sound themes (`pulse sound list`), a file path, or `off`.

## Repository layout

```
reporters/claude-code/   hooks + statusline reporter for Claude Code (bash + jq), VS Code window resolver
lib/pulse-lib.sh         shared state/config helpers, ordering, sounds
ui/gnome/                GNOME Shell extension (GJS, ESM) that renders the state directory
bin/pulse                terminal CLI
test/selftest.sh         replays hook events through the reporter and the CLI
docs/STATE.md            the state-file contract for other providers
install.sh / uninstall.sh / Makefile
```

`make test` runs the self-test, `make lint` syntax-checks everything, `make pack` builds the extension zip for extensions.gnome.org.

## Adding another agent or editor

Write a reporter that keeps `~/.local/state/claude-pulse/sessions/<id>.json` up to date (see [docs/STATE.md](docs/STATE.md)). Set `windowHint` to a substring of the editor window title, `reveal.command` to whatever reveals that session (an editor URI, a tmux command), and `processPattern` to recognise the agent's process. The renderer does the rest.

Other desktops: the extension is GNOME-only; a tray renderer for macOS/Windows only has to watch the same directory.

## Known limits

- The statusline command is not invoked inside the VS Code extension, so model and context come from the transcript (model shows as an id, e.g. `claude-fable-5-1`).
- Two sessions in one window share the window; window focus marks both as viewed, a dot click is exact.
- Changes to `extension.js` need a shell reload; reporter and CLI changes apply immediately.

## License

MIT
