import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const DOT_SIZE = 16;
const RING_WIDTH = 2.5;
const DOT_BOX = DOT_SIZE + 2 * RING_WIDTH + 4;
const REFRESH_INTERVAL_SEC = 10;
const MONITOR_DEBOUNCE_MS = 150;
const STALE_WITHOUT_PID_MS = 24 * 3600 * 1000;

const COLORS = {
    working: [0.25, 0.69, 0.31],
    waiting: [0.85, 0.62, 0.13],
    done: [0.97, 0.32, 0.29],
    idle: [0.55, 0.58, 0.62],
};

const STATE_TITLES = {
    working: 'Working',
    waiting: 'Waiting for you',
    done: 'Finished',
    idle: 'Idle',
};

function readText(path) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        return ok ? new TextDecoder().decode(bytes) : null;
    } catch {
        return null;
    }
}

function readJson(path) {
    const text = readText(path);
    if (!text)
        return null;
    try {
        return JSON.parse(text);
    } catch {
        return null;
    }
}

function basename(path) {
    return path ? path.split('/').filter(Boolean).pop() ?? path : '';
}

function fmtDuration(ms) {
    if (ms == null || ms < 0)
        return '–';
    const totalMin = Math.floor(ms / 60000);
    if (totalMin < 1)
        return `${Math.floor(ms / 1000)}s`;
    const h = Math.floor(totalMin / 60);
    const m = totalMin % 60;
    return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

function fmtTokens(n) {
    if (n == null)
        return '?';
    return n >= 1000 ? `${Math.round(n / 1000)}k` : `${n}`;
}

function cacheRemaining(session) {
    if (!session.cacheExpiresAt)
        return null;
    return session.cacheExpiresAt - Date.now();
}

function cacheFraction(session) {
    const remaining = cacheRemaining(session);
    if (remaining == null || remaining <= 0)
        return 0;
    const ttl = session.cacheTtlMs ?? 3600000;
    return Math.min(1, remaining / ttl);
}

function contextPercent(session) {
    if (session.contextPct != null)
        return Math.round(session.contextPct);
    if (session.contextTokens != null)
        return Math.round(100 * session.contextTokens / (session.contextSize ?? 200000));
    return null;
}

function writeJson(path, value) {
    try {
        GLib.mkdir_with_parents(GLib.path_get_dirname(path), 0o755);
        GLib.file_set_contents(path, JSON.stringify(value, null, 2));
        return true;
    } catch {
        return false;
    }
}

function isVisible(session, mode) {
    if (session.bound === true)
        return true;
    if (session.bound === false || session.hidden === true)
        return false;
    return mode !== 'manual';
}

function normalizeKey(combo) {
    const parts = combo.split('+');
    return parts.map((part, i) => (i === parts.length - 1 && part.length > 1 ? part[0].toUpperCase() + part.slice(1) : part)).join('+');
}

function sortKey(session, order) {
    if (session.order != null)
        return session.order;
    const index = session.windowHint ? order.indexOf(session.windowHint) : -1;
    return index >= 0 ? index : 1e15;
}

function processAlive(pid, pattern) {
    if (!pid)
        return null;
    if (!GLib.file_test(`/proc/${pid}`, GLib.FileTest.IS_DIR))
        return false;
    if (!pattern)
        return true;
    const cmdline = readText(`/proc/${pid}/cmdline`);
    if (cmdline == null)
        return true;
    try {
        return new RegExp(pattern, 'i').test(cmdline);
    } catch {
        return cmdline.toLowerCase().includes(pattern.toLowerCase());
    }
}

const Dot = GObject.registerClass(
class ClaudePulseDot extends St.Widget {
    _init(session, owner) {
        super._init({
            layout_manager: new Clutter.BinLayout(),
            reactive: true,
            track_hover: true,
            width: DOT_BOX,
            height: DOT_BOX,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this.session = session;
        this._owner = owner;
        this._area = new St.DrawingArea({width: DOT_BOX, height: DOT_BOX});
        this._area.connect('repaint', area => this._paint(area));
        this.add_child(this._area);
        this._count = new St.Label({
            style_class: 'claude-pulse-count',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
            x_expand: true,
            y_expand: true,
        });
        this.add_child(this._count);
        this.connect('enter-event', () => this._owner.showTooltip(this));
        this.connect('leave-event', () => this._owner.hideTooltip(this));
        this.connect('scroll-event', (_actor, event) => {
            const direction = event.get_scroll_direction();
            if (direction === Clutter.ScrollDirection.UP || direction === Clutter.ScrollDirection.LEFT)
                this._owner.moveSession(this.session, -1);
            else if (direction === Clutter.ScrollDirection.DOWN || direction === Clutter.ScrollDirection.RIGHT)
                this._owner.moveSession(this.session, 1);
            else
                return Clutter.EVENT_PROPAGATE;
            return Clutter.EVENT_STOP;
        });
        this.connect('button-press-event', (_actor, event) => {
            const button = event.get_button();
            if (button === 1)
                this._owner.focusSession(this.session);
            else if (button === 3)
                this._owner.openMenu(this);
            return Clutter.EVENT_STOP;
        });
        this.update(session);
    }

    update(session) {
        this.session = session;
        const agents = (session.agents ?? []).length;
        this._count.text = agents > 0 ? `${agents}` : '';
        this._setPulsing(session.state === 'done' && session.unseen === true);
        this._area.queue_repaint();
    }

    _setPulsing(on) {
        if (on === this._pulsing)
            return;
        this._pulsing = on;
        this.remove_transition('claude-pulse-breathe');
        if (!on) {
            this.opacity = 255;
            return;
        }
        const transition = new Clutter.PropertyTransition({
            property_name: 'opacity',
            duration: 900,
            progress_mode: Clutter.AnimationMode.EASE_IN_OUT_SINE,
            repeat_count: -1,
            auto_reverse: true,
        });
        transition.set_from(255);
        transition.set_to(70);
        this.add_transition('claude-pulse-breathe', transition);
    }

    _paint(area) {
        const cr = area.get_context();
        const [w, h] = area.get_surface_size();
        const session = this.session;
        const [r, g, b] = COLORS[session.state] ?? COLORS.idle;
        const cx = w / 2;
        const cy = h / 2;
        const radius = DOT_SIZE / 2;

        cr.setSourceRGBA(r, g, b, 1);
        cr.arc(cx, cy, radius, 0, 2 * Math.PI);
        cr.fill();

        if (session.state !== 'working') {
            const fraction = cacheFraction(session);
            if (fraction > 0) {
                cr.setLineWidth(RING_WIDTH);
                cr.setSourceRGBA(r, g, b, 0.5);
                cr.arc(cx, cy, radius + RING_WIDTH / 2 + 1, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * fraction);
                cr.stroke();
            }
        }
        cr.$dispose();
    }
});

class PulseIndicator {
    constructor() {
        this._sessionsDir = GLib.build_filenamev([GLib.get_user_state_dir(), 'claude-pulse', 'sessions']);
        this._configPath = GLib.build_filenamev([GLib.get_user_config_dir(), 'claude-pulse', 'config.json']);
        GLib.mkdir_with_parents(this._sessionsDir, 0o755);

        this._button = new PanelMenu.Button(0.0, 'Claude Pulse', true);
        this._box = new St.BoxLayout({style_class: 'claude-pulse-box', y_align: Clutter.ActorAlign.CENTER});
        this._button.add_child(this._box);
        this._button.visible = false;
        Main.panel.addToStatusArea('claude-pulse', this._button, 0, 'right');

        this._dots = new Map();
        this._tooltip = null;
        this._tooltipDot = null;
        this._menu = null;
        this._menuManager = new PopupMenu.PopupMenuManager(this._button);

        const dir = Gio.File.new_for_path(this._sessionsDir);
        this._monitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
        this._monitorId = this._monitor.connect('changed', () => this._scheduleRefresh());
        const configDir = GLib.path_get_dirname(this._configPath);
        GLib.mkdir_with_parents(configDir, 0o755);
        this._configMonitor = Gio.File.new_for_path(configDir).monitor_directory(Gio.FileMonitorFlags.NONE, null);
        this._configMonitorId = this._configMonitor.connect('changed', () => this._scheduleRefresh());
        this._debounceId = 0;
        this._timerId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, REFRESH_INTERVAL_SEC, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
        this._focusId = global.display.connect('notify::focus-window', () => this._markFocusedSeen());
        this._refresh();
    }

    destroy() {
        if (this._focusId) {
            global.display.disconnect(this._focusId);
            this._focusId = 0;
        }
        this.hideTooltip();
        this._closeMenu();
        if (this._debounceId) {
            GLib.source_remove(this._debounceId);
            this._debounceId = 0;
        }
        if (this._timerId) {
            GLib.source_remove(this._timerId);
            this._timerId = 0;
        }
        if (this._monitor) {
            this._monitor.disconnect(this._monitorId);
            this._monitor.cancel();
            this._monitor = null;
        }
        if (this._configMonitor) {
            this._configMonitor.disconnect(this._configMonitorId);
            this._configMonitor.cancel();
            this._configMonitor = null;
        }
        for (const dot of this._dots.values())
            dot.destroy();
        this._dots.clear();
        this._button.destroy();
        this._button = null;
    }

    _scheduleRefresh() {
        if (this._debounceId)
            GLib.source_remove(this._debounceId);
        this._debounceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, MONITOR_DEBOUNCE_MS, () => {
            this._debounceId = 0;
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    _config() {
        return readJson(this._configPath) ?? {};
    }

    _mode() {
        return this._config().mode === 'manual' ? 'manual' : 'auto';
    }

    _setMode(mode) {
        const config = this._config();
        config.mode = mode;
        writeJson(this._configPath, config);
        this._refresh();
    }

    moveSession(session, delta) {
        const sessions = this._loadSessions();
        const index = sessions.findIndex(s => s.id === session.id);
        if (index < 0)
            return;
        const target = Math.max(0, Math.min(sessions.length - 1, index + delta));
        if (target === index)
            return;
        const [moved] = sessions.splice(index, 1);
        sessions.splice(target, 0, moved);
        const hints = [];
        sessions.forEach((s, i) => {
            const path = GLib.build_filenamev([this._sessionsDir, `${s.id}.json`]);
            const current = readJson(path);
            if (current) {
                current.order = i;
                writeJson(path, current);
            }
            if (s.windowHint && !hints.includes(s.windowHint))
                hints.push(s.windowHint);
        });
        const config = this._config();
        config.order = hints;
        writeJson(this._configPath, config);
        this._refresh();
    }

    _setBound(session, bound) {
        const path = GLib.build_filenamev([this._sessionsDir, `${session.id}.json`]);
        const current = readJson(path);
        if (!current)
            return;
        current.bound = bound;
        current.hidden = !bound;
        writeJson(path, current);
        this._refresh();
    }

    _loadSessions() {
        const config = this._config();
        const mode = config.mode === 'manual' ? 'manual' : 'auto';
        const order = Array.isArray(config.order) ? config.order : [];
        const sessions = [];
        const dir = Gio.File.new_for_path(this._sessionsDir);
        let enumerator;
        try {
            enumerator = dir.enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
        } catch {
            return sessions;
        }
        let info;
        while ((info = enumerator.next_file(null)) !== null) {
            const name = info.get_name();
            if (!name.endsWith('.json'))
                continue;
            const path = GLib.build_filenamev([this._sessionsDir, name]);
            const session = readJson(path);
            if (!session || !session.id)
                continue;
            if (this._isStale(session)) {
                try {
                    Gio.File.new_for_path(path).delete(null);
                } catch {
                }
                continue;
            }
            if (!isVisible(session, mode))
                continue;
            sessions.push(session);
        }
        enumerator.close(null);
        sessions.sort((a, b) => (sortKey(a, order) - sortKey(b, order)) || ((a.startedAt ?? 0) - (b.startedAt ?? 0)));
        return sessions;
    }

    _isStale(session) {
        const alive = processAlive(session.pid, session.processPattern);
        if (alive === false)
            return true;
        if (alive === null && session.lastEventAt && Date.now() - session.lastEventAt > STALE_WITHOUT_PID_MS)
            return true;
        return false;
    }

    _focusedTitle() {
        const win = global.display.focus_window;
        if (!win || !/code/i.test(win.get_wm_class() ?? ''))
            return null;
        return win.get_title() ?? '';
    }

    _sessionInTitle(session, title) {
        if (!title)
            return false;
        const hint = session.windowHint;
        if (hint && (title.includes(`${hint} (Workspace)`) || title.includes(hint)))
            return true;
        const folder = basename(session.cwd);
        return Boolean(folder) && title.includes(folder);
    }

    _markSeen(session) {
        const path = GLib.build_filenamev([this._sessionsDir, `${session.id}.json`]);
        const current = readJson(path);
        if (!current || current.unseen !== true)
            return;
        current.unseen = false;
        writeJson(path, current);
    }

    _markFocusedSeen() {
        const title = this._focusedTitle();
        if (!title)
            return;
        let changed = false;
        for (const dot of this._dots.values()) {
            const session = dot.session;
            if (session.unseen === true && this._sessionInTitle(session, title)) {
                this._markSeen(session);
                changed = true;
            }
        }
        if (changed)
            this._scheduleRefresh();
    }

    _refresh() {
        if (!this._button)
            return;
        const focusedTitle = this._focusedTitle();
        const sessions = this._loadSessions().map(session => {
            if (session.unseen === true && session.state === 'done' && this._sessionInTitle(session, focusedTitle)) {
                this._markSeen(session);
                return {...session, unseen: false};
            }
            return session;
        });
        const seen = new Set();
        sessions.forEach((session, index) => {
            seen.add(session.id);
            let dot = this._dots.get(session.id);
            if (!dot) {
                dot = new Dot(session, this);
                this._dots.set(session.id, dot);
                this._box.insert_child_at_index(dot, index);
            } else {
                dot.update(session);
                this._box.set_child_at_index(dot, index);
            }
        });
        for (const [id, dot] of this._dots) {
            if (seen.has(id))
                continue;
            if (this._tooltipDot === dot)
                this.hideTooltip();
            dot.destroy();
            this._dots.delete(id);
        }
        this._button.visible = sessions.length > 0;
        if (this._tooltipDot && this._tooltip)
            this._tooltip.text = this._describe(this._tooltipDot.session);
    }

    _describe(session) {
        const lines = [];
        lines.push(session.label ?? basename(session.cwd) ?? session.id);
        const agents = (session.agents ?? []).length;
        let stateLine = STATE_TITLES[session.state] ?? session.state;
        if (session.state === 'working' && agents > 0)
            stateLine += ` · ${agents} agent${agents === 1 ? '' : 's'}`;
        if (session.state === 'waiting' && session.reason)
            stateLine += ` · ${session.reason}`;
        if (session.state === 'done' && session.finishedAt)
            stateLine += ` · ${fmtDuration(Date.now() - session.finishedAt)} ago`;
        if (session.state === 'done' && session.unseen === true)
            stateLine += ' · not viewed yet';
        lines.push(stateLine);
        lines.push(`Session: ${session.sessionTitle ?? session.sessionName ?? `#${session.id.slice(0, 8)}`}${session.bound === true ? ' · bound' : ''}`);

        const model = session.model ?? session.modelId ?? 'unknown model';
        const pct = contextPercent(session);
        const ctx = pct == null ? 'ctx ?' : `ctx ${pct}% (${fmtTokens(session.contextTokens)} / ${fmtTokens(session.contextSize ?? 200000)})`;
        lines.push(`${model} · ${ctx}`);

        const total = session.durationMs ?? (session.startedAt ? Date.now() - session.startedAt : null);
        let timeLine = `Running ${fmtDuration(total)}`;
        if (session.state === 'working' && session.turnStartedAt)
            timeLine += ` · this turn ${fmtDuration(Date.now() - session.turnStartedAt)}`;
        if (session.state === 'waiting' && session.waitingSince)
            timeLine += ` · waiting ${fmtDuration(Date.now() - session.waitingSince)}`;
        lines.push(timeLine);

        if (session.state !== 'working') {
            const remaining = cacheRemaining(session);
            if (remaining != null)
                lines.push(remaining > 0 ? `Prompt cache warm, ${fmtDuration(remaining)} left` : 'Prompt cache cold');
        }
        if (session.lastMessage)
            lines.push(`“${session.lastMessage.slice(0, 140)}${session.lastMessage.length > 140 ? '…' : ''}”`);
        if (session.cwd)
            lines.push(session.cwd);
        return lines.join('\n');
    }

    showTooltip(dot) {
        this.hideTooltip();
        const label = new St.Label({style_class: 'claude-pulse-tooltip', text: this._describe(dot.session)});
        label.clutter_text.line_wrap = false;
        Main.layoutManager.addTopChrome(label);
        const [x, y] = dot.get_transformed_position();
        const [w, h] = dot.get_transformed_size();
        const [, natWidth] = label.get_preferred_width(-1);
        const monitor = Main.layoutManager.primaryMonitor;
        let left = Math.round(x + w / 2 - natWidth / 2);
        const maxLeft = monitor.x + monitor.width - natWidth - 8;
        left = Math.max(monitor.x + 8, Math.min(left, maxLeft));
        label.set_position(left, Math.round(y + h + 6));
        this._tooltip = label;
        this._tooltipDot = dot;
    }

    hideTooltip(dot = null) {
        if (dot && this._tooltipDot !== dot)
            return;
        if (this._tooltip) {
            Main.layoutManager.removeChrome(this._tooltip);
            this._tooltip.destroy();
        }
        this._tooltip = null;
        this._tooltipDot = null;
    }

    _closeMenu() {
        if (!this._menu)
            return;
        const menu = this._menu;
        this._menu = null;
        this._menuManager.removeMenu(menu);
        menu.destroy();
    }

    openMenu(dot) {
        this.hideTooltip();
        this._closeMenu();
        const session = dot.session;
        const menu = new PopupMenu.PopupMenu(dot, 0.5, St.Side.TOP);
        Main.uiGroup.add_child(menu.actor);
        menu.actor.hide();
        this._menuManager.addMenu(menu);

        const header = new PopupMenu.PopupMenuItem(session.label ?? basename(session.cwd), {reactive: false});
        menu.addMenuItem(header);
        const status = new PopupMenu.PopupMenuItem(STATE_TITLES[session.state] ?? session.state, {reactive: false});
        status.label.add_style_class_name('claude-pulse-tooltip-muted');
        menu.addMenuItem(status);
        menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const open = new PopupMenu.PopupMenuItem('Open in VS Code');
        open.connect('activate', () => this.focusSession(session));
        menu.addMenuItem(open);

        const moveLeft = new PopupMenu.PopupMenuItem('Move left');
        moveLeft.connect('activate', () => this.moveSession(session, -1));
        menu.addMenuItem(moveLeft);
        const moveRight = new PopupMenu.PopupMenuItem('Move right');
        moveRight.connect('activate', () => this.moveSession(session, 1));
        menu.addMenuItem(moveRight);

        const unbind = new PopupMenu.PopupMenuItem('Unbind (remove from panel)');
        unbind.connect('activate', () => this._setBound(session, false));
        menu.addMenuItem(unbind);

        menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const manual = this._mode() === 'manual';
        const modeItem = new PopupMenu.PopupSwitchMenuItem('Manual mode (bound sessions only)', manual);
        modeItem.connect('toggled', (_item, state) => this._setMode(state ? 'manual' : 'auto'));
        menu.addMenuItem(modeItem);

        menu.connect('open-state-changed', (_menu, isOpen) => {
            if (isOpen)
                return;
            GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                if (this._menu === menu)
                    this._closeMenu();
                return GLib.SOURCE_REMOVE;
            });
        });
        this._menu = menu;
        menu.open(true);
    }

    _findWindow(session) {
        const windows = global.get_window_actors()
            .map(actor => actor.meta_window)
            .filter(win => win && /code/i.test(win.get_wm_class() ?? ''));
        const title = win => win.get_title() ?? '';
        const hint = session.windowHint;
        const folder = basename(session.cwd);
        const candidates = [
            hint && (win => title(win).includes(`${hint} (Workspace)`)),
            hint && (win => title(win).includes(hint)),
            folder && (win => title(win).includes(folder)),
        ].filter(Boolean);
        for (const predicate of candidates) {
            const win = windows.find(predicate);
            if (win)
                return win;
        }
        return null;
    }

    focusSession(session) {
        this.hideTooltip();
        this._markSeen(session);
        const win = this._findWindow(session);
        if (win) {
            Main.activateWindow(win);
            this._revealSession(session, 300);
            return;
        }
        const launch = Array.isArray(session.launch?.command)
            ? session.launch.command.map(String)
            : (session.workspaceFile ?? session.cwd) ? ['code', session.workspaceFile ?? session.cwd] : null;
        if (!launch)
            return;
        try {
            GLib.spawn_async(null, launch, null, GLib.SpawnFlags.SEARCH_PATH, null);
            this._revealSession(session, 4000);
        } catch (e) {
            Main.notify('Claude Pulse', `Could not launch the editor: ${e.message}`);
        }
    }

    _revealSession(session, delayMs) {
        const command = Array.isArray(session.reveal?.command) ? session.reveal.command.map(String) : null;
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, delayMs, () => {
            if (command && command.length > 0) {
                try {
                    GLib.spawn_async(null, command, null, GLib.SpawnFlags.SEARCH_PATH, null);
                } catch {
                }
            }
            this._sendFocusKey();
            return GLib.SOURCE_REMOVE;
        });
    }

    _sendFocusKey() {
        const config = readJson(this._configPath) ?? {};
        if (!config.focusKey)
            return;
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 450, () => {
            try {
                GLib.spawn_async(null, ['xdotool', 'key', '--clearmodifiers', normalizeKey(config.focusKey)], null, GLib.SpawnFlags.SEARCH_PATH, null);
            } catch {
            }
            return GLib.SOURCE_REMOVE;
        });
    }
}

export default class ClaudePulseExtension extends Extension {
    enable() {
        this._indicator = new PulseIndicator();
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
