/* AuroraOS Lock Menu — GNOME 43 Shell extension.
 *
 * Goal: the Lock button in the system (Quick Settings) menu should ALWAYS be
 * visible. The live user has no password by default, so AuroraOS keeps the
 * lockdown key `disable-lock-screen` = true in that state (which normally HIDES
 * the lock button). This extension force-shows it and, when there is no password,
 * makes a click open "Set a Password" instead of locking the user out. Once a
 * password is set, aurora-set-password flips disable-lock-screen = false and the
 * normal lock behavior takes over.
 *
 * Everything is wrapped in try/catch + logError so a wrong selector can never
 * break the shell — worst case the extension is a no-op.
 */
const { Gio, GLib, Clutter } = imports.gi;
const Main = imports.ui.main;

const LOCK_ICONS = [
    'system-lock-screen-symbolic',
    'changes-prevent-symbolic',
];

let _settings = null;
let _lockBtn = null;
let _pressId = 0;
let _visId = 0;

function init() {}

function _noPassword() {
    try { return _settings.get_boolean('disable-lock-screen'); }
    catch (e) { return false; }
}

function _iconNameOf(actor) {
    try {
        if (!actor) return null;
        if (actor.get_icon_name) return actor.get_icon_name();
        if (actor.icon_name) return actor.icon_name;
        if (actor.child && actor.child.icon_name) return actor.child.icon_name;
    } catch (e) {}
    return null;
}

// Walk the Quick Settings system item's buttons and return the lock one.
function _findLockButton() {
    try {
        const qs = Main.panel.statusArea.quickSettings;
        if (!qs || !qs._system) return null;
        const items = qs._system.quickSettingsItems || [];
        for (const it of items) {
            const box = it.child || it;
            const kids = (box && box.get_children) ? box.get_children() : [];
            for (const k of kids) {
                if (LOCK_ICONS.includes(_iconNameOf(k))) return k;
                const sub = (k && k.get_children) ? k.get_children() : [];
                for (const s of sub) {
                    if (LOCK_ICONS.includes(_iconNameOf(s))) return k;
                }
            }
        }
    } catch (e) { logError(e, 'aurora-lockmenu: find'); }
    return null;
}

function _openSetPassword() {
    try {
        Main.panel.statusArea.quickSettings.menu.close();
    } catch (e) {}
    try {
        GLib.spawn_command_line_async(
            'gnome-terminal --title=Set\\ a\\ Password -- sudo aurora-set-password');
    } catch (e) {
        logError(e, 'aurora-lockmenu: spawn set-password');
    }
}

function enable() {
    try {
        _settings = new Gio.Settings({ schema_id: 'org.gnome.desktop.lockdown' });
        _lockBtn = _findLockButton();
        if (!_lockBtn) {
            log('aurora-lockmenu: lock button not found (GNOME internals differ?)');
            return;
        }

        // Keep it visible even when lockdown would hide it.
        _lockBtn.visible = true;
        _visId = _lockBtn.connect('notify::visible', () => {
            if (!_lockBtn.visible) _lockBtn.visible = true;
        });

        // Intercept the press so that, with no password, we offer to set one
        // instead of letting the (disabled) lock action strand the user. With a
        // password set, we propagate and the normal lock runs.
        _pressId = _lockBtn.connect('button-press-event', () => {
            if (_noPassword()) {
                _openSetPassword();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
    } catch (e) { logError(e, 'aurora-lockmenu: enable'); }
}

function disable() {
    try { if (_lockBtn && _pressId) _lockBtn.disconnect(_pressId); } catch (e) {}
    try { if (_lockBtn && _visId) _lockBtn.disconnect(_visId); } catch (e) {}
    _pressId = 0; _visId = 0; _lockBtn = null; _settings = null;
}
