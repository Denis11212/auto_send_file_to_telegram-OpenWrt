#!/bin/sh

PKG_SOURCE="auto_send_file_to_telegramSource"
LUCI_SOURCE="auto_send_file_to_telegramLuciSource"
I18N_SOURCE="auto_send_file_to_telegramI18nSource"
SCRIPT_URL='https://github.com/Denis11212/auto_send_file_to_telegram/raw/refs/heads/main/auto_send_file_to_telegram.sh'

# ============================================================
# ЗАГРУЗКА ipkg-build
# ============================================================
download_ipkg_build()
{
    echo "Загрузка ipkg-build…"
    curl -Ls -O "https://github.com/openwrt/openwrt/raw/refs/heads/main/scripts/ipkg-build"
    chmod +x ./ipkg-build
}

# ============================================================
# ОСНОВНОЙ ПАКЕТ
# ============================================================
compile_main_package()
{
    echo "Загрузка скрипта auto_send_file_to_telegram…"
    mkdir -p "$PKG_SOURCE/usr/bin"
    curl -Ls -o "$PKG_SOURCE/usr/bin/auto_send_file_to_telegram.sh" "$SCRIPT_URL"
    chmod +x "$PKG_SOURCE/usr/bin/auto_send_file_to_telegram.sh"

    mkdir -p "$PKG_SOURCE/usr/lib/auto_send_file_to_telegram"
    cat << 'WRAPEOF' > "$PKG_SOURCE/usr/lib/auto_send_file_to_telegram/run.sh"
#!/bin/sh
# Обёртка для корректного завершения inotifywait + основной скрипт.
# Работает без pkill — только /proc/*/cmdline + встроенная команда kill.

CHILD_PID=""
TERM_RECEIVED=0

# Ищем PID процесса по подстроке в cmdline (аналог pgrep)
find_pids_by_cmdline() {
    local pattern="$1"
    local p pid result=""
    for p in /proc/[0-9]*/cmdline; do
        [ -e "$p" ] || continue
        if tr '\000' ' ' < "$p" 2>/dev/null | grep -q "$pattern"; then
            pid="${p#/proc/}"
            pid="${pid%%/*}"
            result="$result $pid"
        fi
    done
    printf '%s' "$result"
}

cleanup() {
    TERM_RECEIVED=1

    # 1. SIGTERM основному скрипту
    if [ -n "$CHILD_PID" ]; then
        kill -TERM "$CHILD_PID" 2>/dev/null
    fi

    # 2. SIGTERM всем inotifywait, связанным с нашей папкой
    local pids pid
    pids="$(find_pids_by_cmdline 'inotifywait')"
    for pid in $pids; do
        if tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "auto_send_file_to_telegram"; then
            kill -TERM "$pid" 2>/dev/null
        fi
    done

    # 3. SIGTERM всем экземплярам основного скрипта (кроме себя)
    pids="$(find_pids_by_cmdline 'auto_send_file_to_telegram\.sh')"
    for pid in $pids; do
        [ "$pid" != "$$" ] && kill -TERM "$pid" 2>/dev/null
    done

    # 4. Ждём 2 секунды
    sleep 2

    # 5. SIGKILL если кто-то остался
    if [ -n "$CHILD_PID" ]; then
        kill -KILL "$CHILD_PID" 2>/dev/null
    fi
    pids="$(find_pids_by_cmdline 'inotifywait')"
    for pid in $pids; do
        if tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "auto_send_file_to_telegram"; then
            kill -KILL "$pid" 2>/dev/null
        fi
    done
    pids="$(find_pids_by_cmdline 'auto_send_file_to_telegram\.sh')"
    for pid in $pids; do
        [ "$pid" != "$$" ] && kill -KILL "$pid" 2>/dev/null
    done

    exit 0
}

# Перехватываем сигналы завершения
trap cleanup TERM INT HUP QUIT EXIT

# Запускаем основной скрипт в фоне
/usr/bin/auto_send_file_to_telegram.sh &
CHILD_PID=$!

# Блокирующее ожидание
while kill -0 "$CHILD_PID" 2>/dev/null; do
    wait "$CHILD_PID" 2>/dev/null
    [ $TERM_RECEIVED -eq 1 ] && break
done

# Если дошли сюда без сигнала — выходим нормально
[ $TERM_RECEIVED -eq 0 ] && cleanup
WRAPEOF
    chmod +x "$PKG_SOURCE/usr/lib/auto_send_file_to_telegram/run.sh"

    # ---------- init.d (procd, без pkill) ----------
    mkdir -p "$PKG_SOURCE/etc/init.d"
    cat << 'INITEOF' > "$PKG_SOURCE/etc/init.d/auto_send_file_to_telegram"
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

PROG=/usr/bin/auto_send_file_to_telegram.sh
WRAPPER=/usr/lib/auto_send_file_to_telegram/run.sh

# Аналог pkill — убиваем процессы по подстроке в cmdline.
# Работает на любом BusyBox (только /proc + kill).
kill_by_pattern() {
    local pattern="$1"
    local p pid
    for p in /proc/[0-9]*/cmdline; do
        [ -e "$p" ] || continue
        if tr '\000' ' ' < "$p" 2>/dev/null | grep -q "$pattern"; then
            pid="${p#/proc/}"
            pid="${pid%%/*}"
            [ "$pid" != "$$" ] && kill -KILL "$pid" 2>/dev/null
        fi
    done
}

start_service() {
    config_load "auto_send_file_to_telegram"

    if [ ! -x "$PROG" ]; then
        logger -t auto_send_file_to_telegram "Error: script not found: $PROG"
        return 1
    fi
    if [ ! -x "$WRAPPER" ]; then
        logger -t auto_send_file_to_telegram "Error: wrapper not found: $WRAPPER"
        return 1
    fi

    # Убиваем старые процессы перед запуском (защита от сирот)
    kill_by_pattern "inotifywait.*auto_send_file_to_telegram"
    kill_by_pattern "auto_send_file_to_telegram\.sh"
    sleep 1

    # Читаем настройки из UCI
    config_get bot_token  "bot_auth"   bot_token  ""
    config_get chat_id    "bot_auth"   chat_id    ""
    config_get watch_dir   "sub_folder" sub_folder_name_path "/tmp/auto_send_file_to_telegram/new"
    config_get fail_dir    "sub_folder" sub_folder_name      "/tmp/auto_send_file_to_telegram/failed_files"
    config_get_bool user_debug   "debug" user_debug   0
    config_get log_path          "debug" user_debug_path ""

    # Валидация
    if [ -z "$bot_token" ] || [ "$bot_token" = "BOT_TOKEN" ]; then
        logger -t auto_send_file_to_telegram "Error: bot_token is not configured"
        return 1
    fi
    if [ -z "$chat_id" ] || [ "$chat_id" = "CHAT_ID" ]; then
        logger -t auto_send_file_to_telegram "Error: chat_id is not configured"
        return 1
    fi

    # mkdir -p создаёт ВСЕ промежуточные директории
    mkdir -p "$watch_dir" 2>/dev/null
    mkdir -p "$fail_dir" 2>/dev/null
    if [ "$user_debug" = "1" ] && [ -n "$log_path" ]; then
        mkdir -p "$(dirname "$log_path")" 2>/dev/null
    fi

    logger -t auto_send_file_to_telegram "Starting service. Watch: $watch_dir, Fail: $fail_dir"

    procd_open_instance
    procd_set_param command "$WRAPPER"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 60 1
    procd_set_param term_timeout 15
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "auto_send_file_to_telegram"
}

stop_service() {
    kill_by_pattern "inotifywait.*auto_send_file_to_telegram"
    kill_by_pattern "auto_send_file_to_telegram\.sh"
}
INITEOF
    chmod +x "$PKG_SOURCE/etc/init.d/auto_send_file_to_telegram"

    # ---------- UCI config ----------
    mkdir -p "$PKG_SOURCE/etc/config"
    cat << 'UCIEOF' > "$PKG_SOURCE/etc/config/auto_send_file_to_telegram"
config auto_send_file_to_telegram 'global'
	option true_send '1'
	option del_file '1'
	option send_files_with_start '0'

config auto_send_file_to_telegram 'bot_auth'
	option bot_token 'BOT_TOKEN'
	option chat_id 'CHAT_ID'

config auto_send_file_to_telegram 'sub_folder'
	option sub_folder_name_path '/tmp/auto_send_file_to_telegram/new'
	option sub_folder_name '/tmp/auto_send_file_to_telegram/failed_files'

config auto_send_file_to_telegram 'debug'
	option system_debug '0'
	option user_debug '0'
	option user_debug_path '/tmp/auto_send_file_to_telegram/auto_send_file_to_telegram.log'
UCIEOF
    chmod 600 "$PKG_SOURCE/etc/config/auto_send_file_to_telegram"

    # ---------- CONTROL ----------
    mkdir -p "$PKG_SOURCE/CONTROL"

    cat << 'EOF' > "$PKG_SOURCE/CONTROL/postinst"
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/auto_send_file_to_telegram enable >/dev/null 2>&1
/etc/init.d/auto_send_file_to_telegram start  >/dev/null 2>&1
exit 0
EOF

    cat << 'EOF' > "$PKG_SOURCE/CONTROL/prerm"
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/auto_send_file_to_telegram stop    >/dev/null 2>&1
/etc/init.d/auto_send_file_to_telegram disable >/dev/null 2>&1
exit 0
EOF

    cat << 'EOF' > "$PKG_SOURCE/CONTROL/control"
Package: auto_send_file_to_telegram
Version: 2.2
Depends: curl, grep, sed, inotifywait, jq
Source: feeds/packages/auto_send_file_to_telegram
SourceName: auto_send_file_to_telegram
License: GPL-3.0-only
Section: net
SourceDateEpoch: 1721682000
Architecture: all
URL: https://github.com/Denis11212/auto_send_file_to_telegram
Maintainer: Denis11212 <denis2371@gmail.com>
Installed-Size:
Description: Automatically sends new files from a watched folder to a Telegram bot. Managed via procd with proper process cleanup.
EOF

    chmod +x "$PKG_SOURCE/CONTROL/postinst"
    chmod +x "$PKG_SOURCE/CONTROL/prerm"

    echo "Сборка auto_send_file_to_telegram…"
    LC_ALL=C ./ipkg-build "$PKG_SOURCE/"
    rm -rf "$PKG_SOURCE"
}

# ============================================================
# LUCI-ПАКЕТ
# ============================================================
compile_luci_package()
{
    # ---------- JS View ----------
    mkdir -p "$LUCI_SOURCE/www/luci-static/resources/view"
    cat << 'JSEOF' > "$LUCI_SOURCE/www/luci-static/resources/view/auto_send_file_to_telegram.js"
'use strict';
'require view';
'require form';
'require ui';
'require uci';
'require poll';
'require rpc';

// ==================== RPC BACKEND ====================
var callLoad = rpc.declare({
	object: 'auto_send_file_to_telegram',
	method: 'load',
	expect: {}
});

var callStatus = rpc.declare({
	object: 'auto_send_file_to_telegram',
	method: 'status',
	expect: {}
});

var callService = rpc.declare({
	object: 'auto_send_file_to_telegram',
	method: 'service',
	params: ['action'],
	expect: {}
});

var callDiskInfo = rpc.declare({
	object: 'auto_send_file_to_telegram',
	method: 'disk_info',
	expect: {}
});

var callLogRead = rpc.declare({
	object: 'auto_send_file_to_telegram',
	method: 'log_read',
	params: ['name', 'offset', 'limit'],
	expect: {}
});

var _statusFetching = false;
var _pollsActive = true;

// ==================== HELPERS ====================
function esc(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

function fmtSize(bytes) {
	if (bytes === null || bytes === undefined || isNaN(bytes)) return _('N/A');
	if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(2) + ' ' + _('GB');
	if (bytes >= 1048576) return (bytes / 1048576).toFixed(2) + ' ' + _('MB');
	if (bytes >= 1024) return (bytes / 1024).toFixed(2) + ' ' + _('KB');
	return bytes + ' ' + _('B');
}

function fmtUptime(seconds) {
	if (!seconds || isNaN(seconds) || seconds < 0) return _('N/A');
	var d = Math.floor(seconds / 86400);
	var h = Math.floor((seconds % 86400) / 3600);
	var m = Math.floor((seconds % 3600) / 60);
	var s = Math.floor(seconds % 60);
	var parts = [];
	if (d > 0) parts.push(d + _('d'));
	if (h > 0 || d > 0) parts.push(h + _('h'));
	if (m > 0 || h > 0 || d > 0) parts.push(m + _('m'));
	parts.push(s + _('s'));
	return parts.join(' ');
}

function setEl(id, text) {
	var el = document.getElementById(id);
	if (el) el.textContent = text;
}

function waitForState(expectRunning, initialDelay, maxWait) {
	initialDelay = initialDelay || 0;
	maxWait = maxWait || 12000;
	return new Promise(function(resolve) {
		var started = Date.now();
		function check() {
			callStatus().then(function(res) {
				var running = !!(res && res.ok && res.running);
				if (running === expectRunning || (Date.now() - started) > maxWait) {
					resolve(running);
				} else {
					window.setTimeout(check, 600);
				}
			}).catch(function() {
				if ((Date.now() - started) > maxWait) resolve(false);
				else window.setTimeout(check, 600);
			});
		}
		window.setTimeout(check, initialDelay);
	});
}

// ==================== LOG VIEWER ====================
function isNearBottom(el, threshold) {
	if (!el) return true;
	threshold = threshold || 40;
	return el.scrollHeight - el.scrollTop - el.clientHeight < threshold;
}

function copyNode(node) {
	if (!node) return;
	var text = node.textContent || '';
	var done = function() {
		ui.addNotification(null, E('p', _('Log copied to clipboard.')));
	};
	var fallback = function() {
		try {
			var range = document.createRange();
			range.selectNodeContents(node);
			var sel = window.getSelection();
			sel.removeAllRanges();
			sel.addRange(range);
			var ok = document.execCommand('copy');
			if (ok) done();
			else ui.addNotification(null, E('p', _('Copy failed. Please select text manually.')));
		} catch (e) {
			ui.addNotification(null, E('p', _('Copy failed. Please select text manually.')));
		}
	};
	if (window.navigator && navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(text).then(done).catch(fallback);
	} else {
		fallback();
	}
}

function openLiveTail(logname, title) {
	var offset = 0;
	var initialized = false;
	var liveInterval = null;
	var isLive = false;

	var logContainer = E('pre', {
		style: 'max-height:500px; overflow:auto; background:#1e1e1e; color:#d4d4d4; padding:15px; font-family:monospace; white-space:pre; font-size:.85em; border:1px solid #444;'
	});

	var statusDiv = E('div', {
		style: 'margin-bottom:10px; padding:8px; background:#2d2d2d; border-radius:4px; font-family:monospace; font-size:.9em;'
	});

	var toggleButton = E('button', {
		'class': 'cbi-button cbi-button-action',
		style: 'margin-right:10px;'
	}, _('Start Live Tail'));

	var closeButton = E('button', { 'class': 'btn' }, _('Close'));

	function loadLogs() {
		return callLogRead(logname, offset, 65536).then(function(res) {
			if (!res || !res.ok) {
				if (!initialized) logContainer.textContent = _('Failed to read log: ') + (res && res.error ? res.error : 'unknown');
				return;
			}
			if (!res.exists) {
				if (!initialized) logContainer.textContent = _('Log file is empty or does not exist yet.');
				return;
			}
			if (initialized && typeof res.size === 'number' && res.size < offset) {
				logContainer.textContent = '';
				initialized = false;
				offset = 0;
			}
			var stick = !initialized ? true : isNearBottom(logContainer);
			var oldScrollTop = logContainer.scrollTop;

			if (!initialized) {
				logContainer.textContent = res.content || '';
				initialized = true;
			} else if (res.content) {
				var span = document.createElement('span');
				span.style.color = '#4ec9b0';
				span.style.fontWeight = 'bold';
				span.textContent = res.content;
				logContainer.appendChild(span);
				setTimeout(function() {
					span.style.color = '#d4d4d4';
					span.style.fontWeight = 'normal';
				}, 3000);
			}

			if (typeof res.next === 'number') offset = res.next;
			else if (typeof res.size === 'number') offset = res.size;

			if (stick) logContainer.scrollTop = logContainer.scrollHeight;
			else logContainer.scrollTop = oldScrollTop;
		}).catch(function(err) {
			if (!initialized) logContainer.textContent = _('Failed to read log: ') + err;
		});
	}

	function startLive() {
		if (isLive) return;
		isLive = true;
		toggleButton.textContent = _('Stop Live Tail');
		toggleButton.classList.remove('cbi-button-action');
		toggleButton.classList.add('cbi-button-reset');
		statusDiv.innerHTML = '<span style="color:#4ec9b0;">🔄 ' + _('Live tail active') + '</span>';
		liveInterval = setInterval(loadLogs, 1000);
	}

	function stopLive() {
		if (!isLive) return;
		isLive = false;
		toggleButton.textContent = _('Start Live Tail');
		toggleButton.classList.remove('cbi-button-reset');
		toggleButton.classList.add('cbi-button-action');
		statusDiv.innerHTML = '<span style="color:#888;">' + _('Live tail paused') + '</span>';
		if (liveInterval) { clearInterval(liveInterval); liveInterval = null; }
	}

	toggleButton.onclick = function() { isLive ? stopLive() : startLive(); };
	closeButton.onclick = function() { stopLive(); ui.hideModal(); };

	var toolbar = E('div', { style: 'margin-bottom:10px;' }, [
		toggleButton,
		E('button', {
			'class': 'btn',
			style: 'margin-right:10px;',
			click: function() { copyNode(logContainer); }
		}, _('Copy log')),
		closeButton
	]);

	ui.showModal(title, [
		statusDiv,
		toolbar,
		E('div', {}, [logContainer])
	]);

	statusDiv.innerHTML = '<span style="color:#888;">' + _('Source:') + ' ' + esc(logname) + '</span>';
	loadLogs();
}

// ==================== STATUS CARD ====================
function updateStatusCard() {
	if (_statusFetching || !_pollsActive) return Promise.resolve();
	var card = document.getElementById('asft-card');
	if (!card) return Promise.resolve();
	_statusFetching = true;

	return callLoad().then(function(loadRes) {
		_statusFetching = false;
		if (!loadRes || !loadRes.ok) return;

		var service = loadRes.service || {};
		var proc = loadRes.proc || {};
		var running = !!service.running;

		var st = document.getElementById('asft-state');
		if (running) {
			card.style.background = '#e8f5e9';
			card.style.borderLeftColor = '#28a745';
			if (st) { st.style.color = '#28a745'; st.textContent = '▶ ' + _('Running'); }
		} else {
			card.style.background = '#ffebee';
			card.style.borderLeftColor = '#dc3545';
			if (st) { st.style.color = '#dc3545'; st.textContent = '⏸ ' + _('Stopped'); }
		}

		if (proc.available && proc.pid) {
			setEl('asft-pid', String(proc.pid));
			setEl('asft-uptime', proc.uptime_sec > 0 ? fmtUptime(proc.uptime_sec) : _('N/A'));
			setEl('asft-mem', proc.rss_kb > 0 ? fmtSize(proc.rss_kb * 1024) : _('N/A'));
			setEl('asft-cmd', proc.cmdline || '—');
		} else {
			setEl('asft-pid', _('N/A'));
			setEl('asft-uptime', _('N/A'));
			setEl('asft-mem', _('N/A'));
			setEl('asft-cmd', '—');
		}

		var btnStart   = document.getElementById('cbid.auto_send_file_to_telegram.global._btn_start');
		var btnRestart = document.getElementById('cbid.auto_send_file_to_telegram.global._btn_restart');
		var btnStop    = document.getElementById('cbid.auto_send_file_to_telegram.global._btn_stop');

		if (btnStart)   { var r = btnStart.closest('.cbi-value');   if (r) r.style.display = running ? 'none' : ''; }
		if (btnRestart) { var r = btnRestart.closest('.cbi-value'); if (r) r.style.display = running ? '' : 'none'; }
		if (btnStop)    { var r = btnStop.closest('.cbi-value');    if (r) r.style.display = running ? '' : 'none'; }

		var btnAutoEn  = document.getElementById('cbid.auto_send_file_to_telegram.global._btn_autostart_enable');
		var btnAutoDis = document.getElementById('cbid.auto_send_file_to_telegram.global._btn_autostart_disable');
		if (btnAutoEn)  { var r = btnAutoEn.closest('.cbi-value');  if (r) r.style.display = service.enabled ? 'none' : ''; }
		if (btnAutoDis) { var r = btnAutoDis.closest('.cbi-value'); if (r) r.style.display = service.enabled ? '' : 'none'; }

	}).catch(function() {
		_statusFetching = false;
	});
}

function updateDiskCard() {
	if (!_pollsActive) return Promise.resolve();
	return callDiskInfo().then(function(res) {
		if (!res || !res.ok) return;

		if (res.watch_dir_exists) {
			setEl('asft-watch-files', String(res.watch_file_count));
			setEl('asft-watch-size', fmtSize(res.watch_total_size));
		} else {
			setEl('asft-watch-files', _('dir not found'));
			setEl('asft-watch-size', '—');
		}

		if (res.fail_dir_exists) {
			setEl('asft-fail-files', String(res.fail_file_count));
			setEl('asft-fail-size', fmtSize(res.fail_total_size));
		} else {
			setEl('asft-fail-files', _('dir not found'));
			setEl('asft-fail-size', '—');
		}

		if (res.df_stdout) {
			var lines = res.df_stdout.trim().split('\n');
			if (lines.length > 1) {
				var parts = lines[1].split(/\s+/);
				if (parts.length >= 4) setEl('asft-disk-avail', parts[3]);
			}
		}
	}).catch(function() {});
}

function injectStyle() {
	if (document.getElementById('asft-style')) return;
	var st = document.createElement('style');
	st.id = 'asft-style';
	st.textContent =
		'#asft-card .asft-row{font-size:.9em;color:#555;margin-top:3px;}' +
		'#asft-cmd{font-family:monospace;font-size:.85em;word-break:break-all;}' +
		'.asft-disk-card .asft-row{font-size:.9em;color:#555;margin-top:3px;}' +
		'.asft-section-divider{margin-top:6px;padding-top:6px;border-top:1px solid #e9ecef;}';
	document.head.appendChild(st);
}

// ==================== VIEW ====================
return view.extend({
	load: function() {
		return Promise.all([
			uci.load('auto_send_file_to_telegram'),
			callLoad().catch(function() { return { ok: false }; })
		]).then(function(results) {
			return results;
		});
	},

	render: function(data) {
		var m, s, o;
		var loadRes = data[1] || {};
		var service = loadRes.service || {};
		var proc = loadRes.proc || {};
		var isRunning = !!service.running;
		var isEnabled = !!service.enabled;

		injectStyle();

		m = new form.Map('auto_send_file_to_telegram',
			_('Auto Send File to Telegram'),
			_('Automatically sends new files from a watched folder to a Telegram bot.'));

		// ==================== SERVICE STATUS ====================
		s = m.section(form.NamedSection, 'global', 'auto_send_file_to_telegram', _('Service Status'));

		o = s.option(form.DummyValue, '_status_card', _('Service'));
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			var statusColor, statusBg, statusIcon, statusText;
			if (isRunning) {
				statusColor = '#28a745'; statusBg = '#e8f5e9';
				statusIcon = '▶'; statusText = _('Running');
			} else {
				statusColor = '#dc3545'; statusBg = '#ffebee';
				statusIcon = '⏸'; statusText = _('Stopped');
			}

			function asftRow(label, valueEl, extraStyle) {
				var attrs = { 'class': 'asft-row' };
				if (extraStyle) attrs['style'] = extraStyle;
				return E('div', attrs, [ E('strong', {}, label), ' ', valueEl ]);
			}

			var card = E('div', {
				'id': 'asft-card',
				'style': 'background:' + statusBg + '; border-left:4px solid ' + statusColor +
					'; padding:12px 15px; border-radius:4px; transition:background .4s, border-color .4s;'
			}, [
				E('div', {
					'id': 'asft-state',
					'style': 'font-size:1.2em; font-weight:bold; color:' + statusColor + '; transition:color .4s;'
				}, statusIcon + ' ' + statusText),
				asftRow(_('PID:'), E('span', { id: 'asft-pid' }, proc.pid ? String(proc.pid) : _('N/A')), 'margin-top:8px;'),
				asftRow(_('Uptime:'), E('span', { id: 'asft-uptime' }, proc.uptime_sec > 0 ? fmtUptime(proc.uptime_sec) : _('N/A'))),
				asftRow(_('Memory (RSS):'), E('span', { id: 'asft-mem' }, proc.rss_kb > 0 ? fmtSize(proc.rss_kb * 1024) : _('N/A'))),
				E('div', { 'class': 'asft-row', 'style': 'margin-top:6px;' }, [
					E('strong', {}, _('Command:')), ' ',
					E('code', { 'id': 'asft-cmd' }, proc.cmdline || '—')
				])
			]);
			return E('div', { 'class': 'cbi-value-field' }, card);
		};

		// Кнопки управления
		o = s.option(form.Button, '_btn_start');
		o.title = _('Start service');
		o.inputstyle = 'action';
		o.inputtitle = _('Start');
		o.onclick = function() {
			return callService('start').then(function() {
				return waitForState(true, 300, 10000);
			}).then(function() {
				updateStatusCard();
				updateDiskCard();
			});
		};

		o = s.option(form.Button, '_btn_restart');
		o.title = _('Restart service');
		o.inputstyle = 'action';
		o.inputtitle = _('Restart');
		o.onclick = function() {
			return callService('restart').then(function() {
				return waitForState(true, 1000, 15000);
			}).then(function() {
				updateStatusCard();
				updateDiskCard();
			});
		};

		o = s.option(form.Button, '_btn_stop');
		o.title = _('Stop service');
		o.inputstyle = 'negative';
		o.inputtitle = _('Stop');
		o.onclick = function() {
			return callService('stop').then(function() {
				return waitForState(false, 0, 15000);
			}).then(function() {
				updateStatusCard();
				updateDiskCard();
			});
		};

		// Автостарт
		o = s.option(form.Button, '_btn_autostart_enable');
		o.title = _('Autostart');
		o.inputstyle = 'negative';
		o.inputtitle = _('Disabled');
		o.onclick = function() {
			return callService('enable').then(function() {
				ui.addNotification(null, E('p', _('Autostart enabled.')));
				updateStatusCard();
			});
		};

		o = s.option(form.Button, '_btn_autostart_disable');
		o.title = _('Autostart');
		o.inputstyle = 'positive';
		o.inputtitle = _('Enabled');
		o.onclick = function() {
			return callService('disable').then(function() {
				ui.addNotification(null, E('p', _('Autostart disabled.')));
				updateStatusCard();
			});
		};

		// ==================== INFORMATION ABOUT 4 PROCESSES ====================
		s = m.section(form.NamedSection, 'global', 'auto_send_file_to_telegram', _('About Processes'));

		o = s.option(form.DummyValue, '_process_info', _('Why 4 processes?'));
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			return E('div', { 'class': 'cbi-value-field' }, [
				E('div', {
					style: 'padding:12px 15px; background:#e3f2fd; border-left:4px solid #2196f3; border-radius:4px;'
				}, [
					E('div', { 'style': 'font-weight:bold; margin-bottom:8px;' }, [
						'ℹ ', _('Why you see 4 processes in the process list')
					]),
					E('p', { 'style': 'margin:0 0 8px 0; font-size:.9em; color:#444;' }, [
						_('This service normally creates 4 processes. This is expected behavior:')
					]),
					E('table', { 'class': 'table', 'style': 'font-size:.85em; width:100%;' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th' }, _('Process')),
							E('th', { 'class': 'th' }, _('Role'))
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, [E('code', {}, '/bin/sh run.sh')]),
							E('td', { 'class': 'td' }, _('Wrapper — catches stop signals and kills all child processes'))
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, [E('code', {}, '/bin/sh auto_send_file_to_telegram.sh')]),
							E('td', { 'class': 'td' }, _('Main script — parent process'))
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, [E('code', {}, 'inotifywait -m -r ...')]),
							E('td', { 'class': 'td' }, _('File system watcher (left side of shell pipeline)'))
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, [E('code', {}, '/bin/sh auto_send_file_to_telegram.sh')]),
							E('td', { 'class': 'td' }, _('Subshell for the "while read" loop (right side of shell pipeline)'))
						])
					]),
					E('p', { 'style': 'margin:8px 0 0 0; font-size:.85em; color:#666;' }, [
						_('The last two processes exist because the script uses a shell pipeline (inotifywait | while read). Each side of a pipeline runs in its own process. This is standard shell behavior and not a bug. All 4 processes are correctly terminated when the service is stopped or restarted.')
					])
				])
			]);
		};

		// ==================== FOLDER MONITORING ====================
		s = m.section(form.NamedSection, 'global', 'auto_send_file_to_telegram', _('Folder Monitoring'));

		o = s.option(form.DummyValue, '_disk_card', _('Folder Statistics'));
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			var watchDir = uci.get('auto_send_file_to_telegram', 'sub_folder', 'sub_folder_name_path') || '/tmp/auto_send_file_to_telegram/new';
			var failDir  = uci.get('auto_send_file_to_telegram', 'sub_folder', 'sub_folder_name') || '/tmp/auto_send_file_to_telegram/failed_files';

			function asftRow(label, valueEl) {
				return E('div', { 'class': 'asft-row' }, [ E('strong', {}, label), ' ', valueEl ]);
			}

			return E('div', { 'class': 'cbi-value-field' }, [
				E('div', { 'class': 'asft-disk-card', 'style': 'padding:12px 15px; background:#f8f9fa; border-radius:4px; border:1px solid #dee2e6;' }, [
					E('div', { 'class': 'asft-row', 'style': 'font-weight:bold; margin-bottom:8px;' }, [
						_('Watched folder:'), ' ', E('code', {}, watchDir)
					]),
					asftRow(_('Files pending:'), E('span', { id: 'asft-watch-files' }, '—')),
					asftRow(_('Total size:'), E('span', { id: 'asft-watch-size' }, '—')),
					E('div', { 'class': 'asft-row asft-section-divider', 'style': 'font-weight:bold; margin-bottom:8px;' }, [
						_('Failed folder:'), ' ', E('code', {}, failDir)
					]),
					asftRow(_('Files failed:'), E('span', { id: 'asft-fail-files' }, '—')),
					asftRow(_('Total size:'), E('span', { id: 'asft-fail-size' }, '—')),
					E('div', { 'class': 'asft-row asft-section-divider' }, [
						E('strong', {}, _('Disk available:')), ' ',
						E('span', { id: 'asft-disk-avail' }, '—')
					])
				])
			]);
		};

		// ==================== LOGS ====================
		s = m.section(form.NamedSection, 'global', 'auto_send_file_to_telegram', _('Logging & Diagnostics'));

		o = s.option(form.Button, '_viewsyslog');
		o.title = _('System Log (syslog)');
		o.inputtitle = _('View System Log');
		o.description = _('Shows service entries from the system log. Requires "Log to system log" to be enabled in Debug section.');
		o.inputstyle = 'action';
		o.onclick = function() {
			openLiveTail('syslog', _('Service System Log'));
			return Promise.resolve();
		};

		o = s.option(form.Button, '_viewlogfile');
		o.title = _('Service Log File');
		o.inputtitle = _('View Log File (Live Tail)');
		o.description = _('Opens the log file with real-time updates. Requires "Log to file" to be enabled in Debug section.');
		o.inputstyle = 'action';
		o.onclick = function() {
			openLiveTail('logfile', _('Service Log - Live Tail'));
			return Promise.resolve();
		};

		// ==================== GENERAL SETTINGS ====================
		s = m.section(form.NamedSection, 'global', 'auto_send_file_to_telegram', _('General Settings'));

		o = s.option(form.Flag, 'true_send', _('Retry failed sends'));
		o.description = _('If a file cannot be sent, it is moved to the failed folder and retried when a new file appears in the watched folder.');
		o.default = '1';

		o = s.option(form.Flag, 'del_file', _('Delete files after successful send'));
		o.description = _('Once a file is successfully sent, it will be deleted to save space.');
		o.default = '1';

		o = s.option(form.Flag, 'send_files_with_start', _('Send all existing files on startup'));
		o.default = '0';

		// ==================== BOT SETTINGS ====================
		s = m.section(form.NamedSection, 'bot_auth', 'auto_send_file_to_telegram', _('Telegram Bot'));

		o = s.option(form.Value, 'bot_token', _('Bot Token'));
		o.description = _('Get a token from') + ' <a href="https://t.me/BotFather" target="_blank">@BotFather</a>.';
		o.validate = function(section_id, value) {
			if (value === '' || value === 'BOT_TOKEN') return _('Bot token is required');
			if (!/^[0-9]+:[A-Za-z0-9_-]{20,}$/.test(value)) return _('Invalid token format');
			return true;
		};

		o = s.option(form.Value, 'chat_id', _('Chat ID'));
		o.description = _('Your Telegram Chat ID.');
		o.validate = function(section_id, value) {
			if (value === '' || value === 'CHAT_ID') return _('Chat ID is required');
			if (!/^-?[0-9]+$/.test(value)) return _('Chat ID must be a number');
			return true;
		};

		// ==================== FOLDERS ====================
		s = m.section(form.NamedSection, 'sub_folder', 'auto_send_file_to_telegram', _('Folders'));

		o = s.option(form.Value, 'sub_folder_name_path', _('Watched folder'));
		o.placeholder = '/tmp/auto_send_file_to_telegram/new';
		o.validate = function(section_id, value) {
			if (value === '') return _('Path is required');
			if (value.charAt(0) !== '/') return _('Must be an absolute path');
			return true;
		};

		o = s.option(form.Value, 'sub_folder_name', _('Failed files folder'));
		o.placeholder = '/tmp/auto_send_file_to_telegram/failed_files';
		o.validate = function(section_id, value) {
			if (value === '') return _('Path is required');
			if (value.charAt(0) !== '/') return _('Must be an absolute path');
			return true;
		};

		// ==================== DEBUG ====================
		s = m.section(form.NamedSection, 'debug', 'auto_send_file_to_telegram', _('Debug'));

		o = s.option(form.Flag, 'system_debug', _('Log to system log (syslog)'));
		o.default = '0';

		o = s.option(form.Flag, 'user_debug', _('Log to file'));
		o.default = '0';

		o = s.option(form.Value, 'user_debug_path', _('Log file path'));
		o.depends('user_debug', '1');
		o.placeholder = '/tmp/auto_send_file_to_telegram/auto_send_file_to_telegram.log';
		o.validate = function(section_id, value) {
			if (value === '') return _('Path is required');
			if (value.charAt(0) !== '/') return _('Must be an absolute path');
			return true;
		};

		// ==================== POLLING ====================
		var self = this;
		return m.render().then(function(el) {
			var btnStart   = el.querySelector('#cbid\\.auto_send_file_to_telegram\\.global\\._btn_start');
			var btnRestart = el.querySelector('#cbid\\.auto_send_file_to_telegram\\.global\\._btn_restart');
			var btnStop    = el.querySelector('#cbid\\.auto_send_file_to_telegram\\.global\\._btn_stop');
			var btnAutoEn  = el.querySelector('#cbid\\.auto_send_file_to_telegram\\.global\\._btn_autostart_enable');
			var btnAutoDis = el.querySelector('#cbid\\.auto_send_file_to_telegram\\.global\\._btn_autostart_disable');

			if (btnStart)   { var r = btnStart.closest('.cbi-value');   if (r) r.style.display = isRunning ? 'none' : ''; }
			if (btnRestart) { var r = btnRestart.closest('.cbi-value'); if (r) r.style.display = isRunning ? '' : 'none'; }
			if (btnStop)    { var r = btnStop.closest('.cbi-value');    if (r) r.style.display = isRunning ? '' : 'none'; }
			if (btnAutoEn)  { var r = btnAutoEn.closest('.cbi-value');  if (r) r.style.display = isEnabled ? 'none' : ''; }
			if (btnAutoDis) { var r = btnAutoDis.closest('.cbi-value'); if (r) r.style.display = isEnabled ? '' : 'none'; }

			updateStatusCard();
			updateDiskCard();

			self._visHandler = function() {
				if (document.hidden) { _pollsActive = false; }
				else { _pollsActive = true; updateStatusCard(); updateDiskCard(); }
			};
			document.addEventListener('visibilitychange', self._visHandler);

			poll.add(function() { return updateStatusCard(); }, 3);
			poll.add(function() { return updateDiskCard(); }, 5);

			return el;
		});
	},

	remove: function() {
		_pollsActive = false;
		if (this._visHandler) {
			document.removeEventListener('visibilitychange', this._visHandler);
			this._visHandler = null;
		}
	}
});
JSEOF

    # ---------- rpcd ACL ----------
    mkdir -p "$LUCI_SOURCE/usr/share/rpcd/acl.d"
    cat << 'EOF' > "$LUCI_SOURCE/usr/share/rpcd/acl.d/luci-app-auto_send_file_to_telegram.json"
{
	"luci-app-auto_send_file_to_telegram": {
		"description": "Grant access to auto_send_file_to_telegram",
		"read": {
			"uci": [ "auto_send_file_to_telegram" ],
			"ubus": {
				"auto_send_file_to_telegram": [
					"load",
					"status",
					"disk_info",
					"log_read"
				]
			}
		},
		"write": {
			"uci": [ "auto_send_file_to_telegram" ],
			"ubus": {
				"auto_send_file_to_telegram": [
					"service"
				]
			}
		}
	}
}
EOF

    # ---------- rpcd backend (без pkill) ----------
    mkdir -p "$LUCI_SOURCE/usr/libexec/rpcd"
    cat << 'RPCEOF' > "$LUCI_SOURCE/usr/libexec/rpcd/auto_send_file_to_telegram"
#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /usr/share/libubox/jshn.sh

WRAPPER="/usr/lib/auto_send_file_to_telegram/run.sh"
MAX_LOG=262144

json_error() {
	json_init
	json_add_boolean ok 0
	json_add_string error "$1"
	json_dump
	exit 0
}

cfg_get() {
	local val
	val="$(uci -q get "auto_send_file_to_telegram.$1.$2" 2>/dev/null)"
	printf '%s' "$val"
}

# Ищем PID через /proc/*/cmdline (без pgrep)
get_pid() {
	local p pid
	for p in /proc/[0-9]*/cmdline; do
		[ -e "$p" ] || continue
		if tr '\000' ' ' < "$p" 2>/dev/null | grep -q "auto_send_file_to_telegram"; then
			pid="${p#/proc/}"
			pid="${pid%%/*}"
			printf '%s' "$pid"
			return
		fi
	done
	printf ''
}

get_process_info() {
	local pid rss upt starttime hz proc_uptime cmdline rest
	pid=$(get_pid)
	if [ -z "$pid" ] || [ ! -r "/proc/$pid/stat" ]; then
		printf ''
		return
	fi
	rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
	cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
	upt=$(awk '{printf "%d",$1}' /proc/uptime 2>/dev/null)
	hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
	rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null)
	starttime=$(printf '%s' "$rest" | awk '{print $20}')
	starttime=${starttime:-0}
	proc_uptime=$((upt - starttime / hz))
	printf '%s|%s|%s|%s' "$pid" "${rss:-0}" "$proc_uptime" "$cmdline"
}

count_files_in_dir() {
	local dir="$1"
	if [ ! -d "$dir" ]; then
		printf '0|0|0'
		return
	fi
	local count=0 total_size=0
	for f in "$dir"/*; do
		[ -f "$f" ] || continue
		count=$((count + 1))
		local sz
		sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
		total_size=$((total_size + ${sz:-0}))
	done
	printf '%s|%s|1' "$count" "$total_size"
}

method_load() {
	local running=0 enabled=0 raw pid
	/etc/init.d/auto_send_file_to_telegram status >/dev/null 2>&1 && running=1
	/etc/init.d/auto_send_file_to_telegram enabled >/dev/null 2>&1 && enabled=1
	pid="$(get_pid)"
	raw="$(get_process_info)"

	json_init
	json_add_boolean ok 1
	json_add_object service
	json_add_boolean running "$running"
	json_add_boolean enabled "$enabled"
	[ -n "$pid" ] && json_add_int pid "$pid"
	json_close_object

	json_add_object proc
	if [ -n "$raw" ]; then
		json_add_boolean available 1
		local OLD_IFS="$IFS"
		IFS="|"
		set -- $raw
		IFS="$OLD_IFS"
		json_add_int pid "${1:-0}"
		json_add_int rss_kb "${2:-0}"
		json_add_int uptime_sec "${3:-0}"
		json_add_string cmdline "${4:-}"
	else
		json_add_boolean available 0
	fi
	json_close_object
	json_dump
}

method_status() {
	local running=0 enabled=0 pid
	/etc/init.d/auto_send_file_to_telegram status >/dev/null 2>&1 && running=1
	/etc/init.d/auto_send_file_to_telegram enabled >/dev/null 2>&1 && enabled=1
	pid="$(get_pid)"
	json_init
	json_add_boolean ok 1
	json_add_boolean running "$running"
	json_add_boolean enabled "$enabled"
	[ -n "$pid" ] && json_add_int pid "$pid"
	json_dump
}

method_service() {
	local action="$1" rc=1
	case "$action" in
		start|stop|restart|enable|disable)
			"/etc/init.d/auto_send_file_to_telegram" "$action" >/dev/null 2>&1
			rc=$?
			;;
		*)
			json_error "unsupported action"
			;;
	esac
	json_init
	json_add_boolean ok "$([ $rc -eq 0 ] && echo 1 || echo 0)"
	json_add_int rc "$rc"
	json_dump
}

method_disk_info() {
	local watch_dir fail_dir
	watch_dir="$(cfg_get sub_folder sub_folder_name_path)"
	[ -n "$watch_dir" ] || watch_dir="/tmp/auto_send_file_to_telegram/new"
	fail_dir="$(cfg_get sub_folder sub_folder_name)"
	[ -n "$fail_dir" ] || fail_dir="/tmp/auto_send_file_to_telegram/failed_files"

	json_init
	json_add_boolean ok 1

	if [ -d "$watch_dir" ]; then
		json_add_boolean watch_dir_exists 1
		local IFS_OLD="$IFS"
		IFS="|"
		set -- $(count_files_in_dir "$watch_dir")
		IFS="$IFS_OLD"
		json_add_int watch_file_count "${1:-0}"
		json_add_int watch_total_size "${2:-0}"
	else
		json_add_boolean watch_dir_exists 0
	fi

	if [ -d "$fail_dir" ]; then
		json_add_boolean fail_dir_exists 1
		local IFS_OLD="$IFS"
		IFS="|"
		set -- $(count_files_in_dir "$fail_dir")
		IFS="$IFS_OLD"
		json_add_int fail_file_count "${1:-0}"
		json_add_int fail_total_size "${2:-0}"
	else
		json_add_boolean fail_dir_exists 0
	fi

	local df_out
	df_out="$(df -h "${watch_dir%/*}" 2>/dev/null || df -h /tmp 2>/dev/null)"
	json_add_string df_stdout "$df_out"

	json_dump
}

method_log_read() {
	local name="$1" offset="$2" limit="$3"
	local f size chunk chunk_len next

	[ -n "$name" ] || json_error "name required"
	[ -n "$offset" ] || offset=0
	[ -n "$limit" ] || limit=65536
	[ "$limit" -gt "$MAX_LOG" ] && limit="$MAX_LOG"

	if [ "$name" = "syslog" ]; then
		chunk="$(logread -e "auto_send_file_to_telegram" 2>/dev/null | tail -c "$MAX_LOG")"
		json_init
		json_add_boolean ok 1
		json_add_boolean exists 1
		json_add_string content "$chunk"
		json_dump
		return
	fi

	if [ "$name" = "logfile" ]; then
		f="$(cfg_get debug user_debug_path)"
		[ -n "$f" ] || f="/tmp/auto_send_file_to_telegram/auto_send_file_to_telegram.log"
	else
		json_error "unknown log name"
	fi

	if [ ! -f "$f" ]; then
		json_init
		json_add_boolean ok 1
		json_add_boolean exists 0
		json_add_string content ""
		json_add_int size 0
		json_add_int next 0
		json_dump
		return
	fi

	size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
	[ -n "$size" ] || size=0
	[ "$offset" -gt "$size" ] && offset=0

	chunk=""
	if [ "$size" -gt "$offset" ]; then
		chunk="$(tail -c +$((offset + 1)) "$f" 2>/dev/null | head -c "$limit")"
	fi

	chunk_len=$(printf '%s' "$chunk" | wc -c 2>/dev/null | tr -d ' ')
	[ -n "$chunk_len" ] || chunk_len=0
	next=$((offset + chunk_len))
	[ "$next" -gt "$size" ] && next="$size"

	json_init
	json_add_boolean ok 1
	json_add_boolean exists 1
	json_add_int size "$size"
	json_add_int next "$next"
	json_add_string content "$chunk"
	json_dump
}

# ==================== MAIN DISPATCH ====================
case "$1" in
	list)
		cat <<'LISTEOF'
{
	"load": {},
	"status": {},
	"service": {"action":"string"},
	"disk_info": {},
	"log_read": {"name":"string","offset":"number","limit":"number"}
}
LISTEOF
	;;
	call)
		method="$2"
		ACTION=""
		NAME=""
		OFFSET=""
		LIMIT=""
		case "$method" in
			service|log_read)
				json_input="$(cat)"
				if [ -n "$json_input" ]; then
					json_load "$json_input" 2>/dev/null
					json_get_var ACTION action
					json_get_var NAME name
					json_get_var OFFSET offset
					json_get_var LIMIT limit
				fi
				;;
		esac
		case "$method" in
			load)      method_load ;;
			status)    method_status ;;
			service)   method_service "$ACTION" ;;
			disk_info) method_disk_info ;;
			log_read)  method_log_read "$NAME" "$OFFSET" "$LIMIT" ;;
			*) json_error "unknown method" ;;
		esac
	;;
	*)
		exit 1
	;;
esac
RPCEOF
    chmod +x "$LUCI_SOURCE/usr/libexec/rpcd/auto_send_file_to_telegram"

    # ---------- menu.d ----------
    mkdir -p "$LUCI_SOURCE/usr/share/luci/menu.d"
    cat << 'EOF' > "$LUCI_SOURCE/usr/share/luci/menu.d/luci-app-auto_send_file_to_telegram.json"
{
	"admin/services/auto_send_file_to_telegram": {
		"title": "Telegram File Sender",
		"action": {
			"type": "view",
			"path": "auto_send_file_to_telegram"
		},
		"depends": {
			"acl": [ "luci-app-auto_send_file_to_telegram" ],
			"uci": { "auto_send_file_to_telegram": true }
		}
	}
}
EOF

    # ---------- CONTROL ----------
    mkdir -p "$LUCI_SOURCE/CONTROL"

    cat << 'EOF' > "$LUCI_SOURCE/CONTROL/postinst"
#!/bin/sh
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF

    cat << 'EOF' > "$LUCI_SOURCE/CONTROL/prerm"
#!/bin/sh
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF

    cat << 'EOF' > "$LUCI_SOURCE/CONTROL/control"
Package: luci-app-auto_send_file_to_telegram
Version: 2.2
Depends: auto_send_file_to_telegram, luci-base, rpcd
Source: feeds/packages/luci-app-auto_send_file_to_telegram
SourceName: luci-app-auto_send_file_to_telegram
License: GPL-3.0-only
Section: luci
SourceDateEpoch: 1721682000
Architecture: all
URL: https://github.com/Denis11212/auto_send_file_to_telegram
Maintainer: Denis11212 <denis2371@gmail.com>
Installed-Size:
Description: LuCI web interface for auto_send_file_to_telegram with status monitoring, log viewer and service control.
EOF

    chmod +x "$LUCI_SOURCE/CONTROL/postinst"
    chmod +x "$LUCI_SOURCE/CONTROL/prerm"

    echo "Сборка luci-app-auto_send_file_to_telegram…"
    LC_ALL=C ./ipkg-build "$LUCI_SOURCE/"
    rm -rf "$LUCI_SOURCE"
}

# ============================================================
# I18N ПАКЕТ (русский перевод)
# ============================================================
compile_i18n_package()
{
    echo "Сборка пакета русского перевода…"

    LUCI_BASE="https://raw.githubusercontent.com/openwrt/luci/master/modules/luci-base/src"

    mkdir -p po2lmo-src/lib po2lmo-src/contrib
    curl -Ls -o po2lmo-src/po2lmo.c              "$LUCI_BASE/po2lmo.c"
    curl -Ls -o po2lmo-src/lib/lmo.c             "$LUCI_BASE/lib/lmo.c"
    curl -Ls -o po2lmo-src/lib/lmo.h             "$LUCI_BASE/lib/lmo.h"
    curl -Ls -o po2lmo-src/lib/plural_formula.y  "$LUCI_BASE/lib/plural_formula.y"
    curl -Ls -o po2lmo-src/contrib/lemon.c       "$LUCI_BASE/contrib/lemon.c"
    curl -Ls -o po2lmo-src/contrib/lempar.c      "$LUCI_BASE/contrib/lempar.c"

    cd po2lmo-src
    gcc -std=gnu17 -o contrib/lemon contrib/lemon.c >/dev/null 2>&1
    ./contrib/lemon -q lib/plural_formula.y >/dev/null 2>&1
    gcc -c -o po2lmo.o po2lmo.c
    gcc -c -o lib/lmo.o lib/lmo.c -I. -DNDEBUG
    gcc -c -o lib/plural_formula.o lib/plural_formula.c -DNDEBUG
    gcc -o po2lmo po2lmo.o lib/lmo.o lib/plural_formula.o
    cp po2lmo ../po2lmo
    cd ..

    mkdir -p po/ru
    cat << 'POEOF' > po/ru/auto_send_file_to_telegram.po
msgid ""
msgstr ""
"Project-Id-Version: luci-app-auto_send_file_to_telegram\n"
"PO-Revision-Date: 2026-10-29 12:00+0300\n"
"Last-Translator: Denis11212\n"
"Language-Team: Russian\n"
"Language: ru\n"
"MIME-Version: 1.0\n"
"Content-Type: text/plain; charset=UTF-8\n"
"Content-Transfer-Encoding: 8bit\n"
"Plural-Forms: nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);\n"

msgid "Auto Send File to Telegram"
msgstr "Автоотправка файлов в Telegram"

msgid "Automatically sends new files from a watched folder to a Telegram bot."
msgstr "Автоматически отправляет новые файлы из отслеживаемой папки в Telegram-бот."

msgid "Service Status"
msgstr "Состояние службы"

msgid "Service"
msgstr "Служба"

msgid "Running"
msgstr "Запущен"

msgid "Stopped"
msgstr "Остановлен"

msgid "N/A"
msgstr "Н/Д"

msgid "PID:"
msgstr "PID:"

msgid "Uptime:"
msgstr "Время работы:"

msgid "Memory (RSS):"
msgstr "Память (RSS):"

msgid "Command:"
msgstr "Команда:"

msgid "Start service"
msgstr "Запуск службы"

msgid "Start"
msgstr "Запустить"

msgid "Restart service"
msgstr "Перезапуск службы"

msgid "Restart"
msgstr "Перезапустить"

msgid "Stop service"
msgstr "Остановка службы"

msgid "Stop"
msgstr "Остановить"

msgid "Autostart"
msgstr "Автозапуск"

msgid "Disabled"
msgstr "Выключен"

msgid "Enabled"
msgstr "Включен"

msgid "Autostart enabled."
msgstr "Автозапуск включён."

msgid "Autostart disabled."
msgstr "Автозапуск выключен."

msgid "About Processes"
msgstr "О процессах"

msgid "Why 4 processes?"
msgstr "Почему 4 процесса?"

msgid "Why you see 4 processes in the process list"
msgstr "Почему в списке процессов отображаются 4 процесса"

msgid "This service normally creates 4 processes. This is expected behavior:"
msgstr "Эта служба штатно создаёт 4 процесса. Это ожидаемое поведение:"

msgid "Process"
msgstr "Процесс"

msgid "Role"
msgstr "Роль"

msgid "Wrapper — catches stop signals and kills all child processes"
msgstr "Обёртка — перехватывает сигналы остановки и убивает все дочерние процессы"

msgid "Main script — parent process"
msgstr "Основной скрипт — родительский процесс"

msgid "File system watcher (left side of shell pipeline)"
msgstr "Наблюдатель файловой системы (левая часть конвейера)"

msgid "Subshell for the \"while read\" loop (right side of shell pipeline)"
msgstr "Субшелл для цикла «while read» (правая часть конвейера)"

msgid "The last two processes exist because the script uses a shell pipeline (inotifywait | while read). Each side of a pipeline runs in its own process. This is standard shell behavior and not a bug. All 4 processes are correctly terminated when the service is stopped or restarted."
msgstr "Последние два процесса существуют потому, что скрипт использует конвейер (inotifywait | while read). Каждая сторона конвейера выполняется в своём процессе. Это стандартное поведение оболочки, а не ошибка. Все 4 процесса корректно завершаются при остановке или перезапуске службы."

msgid "Folder Monitoring"
msgstr "Мониторинг папок"

msgid "Folder Statistics"
msgstr "Статистика папок"

msgid "Watched folder:"
msgstr "Отслеживаемая папка:"

msgid "Files pending:"
msgstr "Файлов в ожидании:"

msgid "Total size:"
msgstr "Общий размер:"

msgid "Failed folder:"
msgstr "Папка неудачных:"

msgid "Files failed:"
msgstr "Файлов с ошибкой:"

msgid "Disk available:"
msgstr "Доступно на диске:"

msgid "dir not found"
msgstr "папка не найдена"

msgid "Logging & Diagnostics"
msgstr "Логирование и диагностика"

msgid "System Log (syslog)"
msgstr "Системный лог (syslog)"

msgid "View System Log"
msgstr "Просмотр системного лога"

msgid "Shows service entries from the system log. Requires \"Log to system log\" to be enabled in Debug section."
msgstr "Показывает записи службы из системного лога. Требуется включить «Лог в системный журнал» в разделе Отладка."

msgid "Service System Log"
msgstr "Системный лог службы"

msgid "Service Log File"
msgstr "Файл лога службы"

msgid "View Log File (Live Tail)"
msgstr "Просмотр лога (Live Tail)"

msgid "Opens the log file with real-time updates. Requires \"Log to file\" to be enabled in Debug section."
msgstr "Открывает файл лога с обновлениями в реальном времени. Требуется включить «Лог в файл» в разделе Отладка."

msgid "Service Log - Live Tail"
msgstr "Лог службы — Live Tail"

msgid "Start Live Tail"
msgstr "Запустить Live Tail"

msgid "Stop Live Tail"
msgstr "Остановить Live Tail"

msgid "Live tail active"
msgstr "Live tail активен"

msgid "Live tail paused"
msgstr "Live tail на паузе"

msgid "Copy log"
msgstr "Копировать лог"

msgid "Log copied to clipboard."
msgstr "Лог скопирован в буфер обмена."

msgid "Copy failed. Please select text manually."
msgstr "Не удалось скопировать. Выделите текст вручную."

msgid "Failed to read log: "
msgstr "Не удалось прочитать лог: "

msgid "Log file is empty or does not exist yet."
msgstr "Файл лога пуст или ещё не существует."

msgid "Source:"
msgstr "Источник:"

msgid "Close"
msgstr "Закрыть"

msgid "General Settings"
msgstr "Основные настройки"

msgid "Retry failed sends"
msgstr "Повторять неудачные отправки"

msgid "If a file cannot be sent, it is moved to the failed folder and retried when a new file appears in the watched folder."
msgstr "Если файл не удаётся отправить, он перемещается в папку неудачных и будет отправлен при появлении нового файла в отслеживаемой папке."

msgid "Delete files after successful send"
msgstr "Удалять файлы после успешной отправки"

msgid "Once a file is successfully sent, it will be deleted to save space."
msgstr "После успешной отправки файл будет удалён для экономии места."

msgid "Send all existing files on startup"
msgstr "Отправить все существующие файлы при запуске"

msgid "Telegram Bot"
msgstr "Telegram-бот"

msgid "Bot Token"
msgstr "Токен бота"

msgid "Get a token from"
msgstr "Получите токен у"

msgid "Bot token is required"
msgstr "Токен бота обязателен"

msgid "Invalid token format"
msgstr "Неверный формат токена"

msgid "Chat ID"
msgstr "Chat ID"

msgid "Your Telegram Chat ID."
msgstr "Ваш Telegram Chat ID."

msgid "Chat ID is required"
msgstr "Chat ID обязателен"

msgid "Chat ID must be a number"
msgstr "Chat ID должен быть числом"

msgid "Folders"
msgstr "Папки"

msgid "Watched folder"
msgstr "Отслеживаемая папка"

msgid "Path is required"
msgstr "Путь обязателен"

msgid "Must be an absolute path"
msgstr "Должен быть абсолютный путь"

msgid "Failed files folder"
msgstr "Папка неудачных файлов"

msgid "Debug"
msgstr "Отладка"

msgid "Log to system log (syslog)"
msgstr "Лог в системный журнал (syslog)"

msgid "Log to file"
msgstr "Лог в файл"

msgid "Log file path"
msgstr "Путь к файлу лога"

msgid "GB"
msgstr "ГБ"

msgid "MB"
msgstr "МБ"

msgid "KB"
msgstr "КБ"

msgid "B"
msgstr "Б"

msgid "d"
msgstr "д"

msgid "h"
msgstr "ч"

msgid "m"
msgstr "мин"

msgid "s"
msgstr "сек"
POEOF

    mkdir -p "$I18N_SOURCE/usr/lib/lua/luci/i18n"
    ./po2lmo po/ru/auto_send_file_to_telegram.po "$I18N_SOURCE/usr/lib/lua/luci/i18n/auto_send_file_to_telegram.ru.lmo"

    mkdir -p "$I18N_SOURCE/CONTROL"

    cat << 'EOF' > "$I18N_SOURCE/CONTROL/postinst"
#!/bin/sh
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF

    cat << 'EOF' > "$I18N_SOURCE/CONTROL/prerm"
#!/bin/sh
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF

    cat << EOF > "$I18N_SOURCE/CONTROL/control"
Package: luci-i18n-auto_send_file_to_telegram-ru
Version: 2.2
Depends: luci-app-auto_send_file_to_telegram
Source: feeds/packages/luci-app-auto_send_file_to_telegram
SourceName: luci-app-auto_send_file_to_telegram
License: GPL-3.0-only
Section: luci
SourceDateEpoch: 1721682000
Architecture: all
URL: https://github.com/Denis11212/auto_send_file_to_telegram
Maintainer: Denis11212 <denis2371@gmail.com>
Description: Русский перевод для luci-app-auto_send_file_to_telegram
EOF

    chmod +x "$I18N_SOURCE/CONTROL/postinst"
    chmod +x "$I18N_SOURCE/CONTROL/prerm"

    LC_ALL=C ./ipkg-build "$I18N_SOURCE/"

    rm -rf po2lmo-src
    rm -f po2lmo
    rm -rf "$I18N_SOURCE"
    rm -rf po
}

# ============================================================
# MAIN
# ============================================================
download_ipkg_build
compile_main_package
compile_luci_package
compile_i18n_package
rm -rf ipkg-build

while true; do
    read -rp "Работа скрипта завершена. Удалить ли сам скрипт \"$0\"? [Д/н]: " answer
    case "$answer" in
        ""|Д|д|Да|да|Y|y|Yes|yes) rm -rf "$0"; exit 0 ;;
        Н|н|Нет|нет|N|n|No|no) exit 0 ;;
        *) echo "Неправильный ввод. Попробуйте ещё раз." ;;
    esac
done
