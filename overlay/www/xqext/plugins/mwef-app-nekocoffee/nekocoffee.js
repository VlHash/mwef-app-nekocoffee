(function () {
    'use strict';

    var config = window.NEKOCOFFEE_CONFIG || {};
    var state = {
        data: null,
        i18n: {},
        busy: false,
        timer: null,
        stopped: false,
        revision: 0,
        dirtyTraffic: false,
        dirtyDns: false
    };

    function byId(id) {
        return document.getElementById(id);
    }

    function tr(key, fallback) {
        return state.i18n[key] || fallback || key;
    }

    function setText(id, value) {
        var node = byId(id);
        if (node) node.textContent = value == null || value === '' ? '--' : String(value);
    }

    function applyTranslations() {
        var nodes = document.querySelectorAll('[data-i18n]');
        for (var index = 0; index < nodes.length; index += 1) {
            var key = nodes[index].getAttribute('data-i18n');
            if (state.i18n[key]) nodes[index].textContent = state.i18n[key];
        }
    }

    function encode(values) {
        var parts = [];
        Object.keys(values || {}).forEach(function (key) {
            var value = values[key] == null ? '' : values[key];
            parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
        });
        return parts.join('&');
    }

    function request(action, method, payload) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            xhr.open(method || 'GET', config.apiUrl + '?action=' + encodeURIComponent(action), true);
            xhr.timeout = action === 'ip-check' ? 20000 : 25000;
            xhr.setRequestHeader('Accept', 'application/json');
            if (payload) {
                xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
                payload = encode(payload);
            }
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== 4) return;
                var data;
                try {
                    data = JSON.parse(xhr.responseText);
                } catch (error) {
                    reject(new Error(tr('invalidResponse', '服务器返回格式错误')));
                    return;
                }
                if (xhr.status < 200 || xhr.status >= 300 || !data || data.code !== 0) {
                    reject(new Error((data && data.message) || ('HTTP ' + xhr.status)));
                    return;
                }
                resolve(data);
            };
            xhr.onerror = function () { reject(new Error(tr('networkError', '网络请求失败'))); };
            xhr.ontimeout = function () { reject(new Error(tr('requestTimeout', '请求超时'))); };
            xhr.send(payload || null);
        });
    }

    function showMessage(message, error) {
        var node = byId('nekocoffee-message');
        node.hidden = !message;
        node.className = 'mwef-message' + (error ? ' error' : '');
        node.textContent = message || '';
    }

    function setConnection(mode, label) {
        var node = byId('nekocoffee-live');
        node.className = 'nekocoffee-live ' + mode;
        var text = node.querySelector('span');
        if (text) text.textContent = label;
    }

    function hasGrant(permission) {
        var grants = state.data && state.data.grants ? state.data.grants : [];
        return grants.indexOf(permission) >= 0;
    }

    function setBusy(busy) {
        state.busy = busy;
        var buttons = document.querySelectorAll('.nekocoffee-page button');
        for (var index = 0; index < buttons.length; index += 1) {
            if (busy) {
                buttons[index].disabled = true;
            }
        }
        if (busy) {
            byId('nekocoffee-traffic-mode').disabled = true;
            byId('nekocoffee-dns-mode').disabled = true;
        } else if (state.data) {
            render(state.data);
        }
    }

    function proxyModeLabel(value) {
        var labels = {
            rule: tr('ruleMode', '规则'),
            global: tr('globalMode', '全局'),
            direct: tr('directMode', '直连')
        };
        return labels[String(value || '').toLowerCase()] || '--';
    }

    function trafficModeLabel(value) {
        var labels = {
            Mix: tr('modeMix', '混合模式（推荐）'),
            Redir: tr('modeRedir', 'Redir 模式'),
            Tproxy: tr('modeTproxy', 'TProxy 模式'),
            Tun: tr('modeTun', 'TUN 模式')
        };
        return labels[value] || value || '--';
    }

    function dnsModeLabel(value) {
        var labels = {
            redir_host: tr('modeRedirectHost', 'redirect-host（兼容）'),
            'fake-ip': tr('modeFakeIp', 'fake-ip（增强）')
        };
        return labels[value] || value || '--';
    }

    function renderSelect(node, options, current, formatter) {
        while (node.firstChild) node.removeChild(node.firstChild);
        options = options || [];
        if (current && options.indexOf(current) < 0) options = [current].concat(options);
        options.forEach(function (value) {
            var option = document.createElement('option');
            option.value = value;
            option.textContent = formatter(value);
            option.selected = value === current;
            node.appendChild(option);
        });
    }

    function dashboardUrl(details) {
        if (!details || !details.port) return null;
        var host = window.location.hostname || window.location.host.split(':')[0];
        if (host.indexOf(':') >= 0 && host.charAt(0) !== '[') host = '[' + host + ']';
        var path = details.path || '/ui/';
        if (path.charAt(0) !== '/') path = '/' + path;
        return 'http://' + host + ':' + details.port + path;
    }

    function render(data) {
        state.data = data;
        var installation = data.installation || {};
        var runtime = data.runtime || {};
        var settings = data.settings || {};
        var dashboard = data.dashboard || {};
        var running = installation.running === true;

        setText('nekocoffee-installation', installation.detected
            ? (installation.name || 'ShellClash') + ' ' + (installation.version || '')
            : (data.permissionMissing && data.permissionMissing.length
                ? tr('permissionMissing', '缺少所需插件权限，请在框架设置中授权。')
                : tr('notInstalled', '未找到兼容的 ShellClash / ShellCrash 安装')));
        setText('nekocoffee-service-state', installation.detected
            ? (running ? tr('running', '运行中') : tr('stopped', '已停止'))
            : '--');
        byId('nekocoffee-service-state').className = running ? 'is-running' : 'is-stopped';
        setText('nekocoffee-core-version', installation.coreVersion || installation.core || '--');
        setText('nekocoffee-proxy-mode', proxyModeLabel(runtime.proxyMode));
        var runtimeDnsMode = runtime.dnsEnhancedMode === 'redir-host'
            ? 'redir_host'
            : runtime.dnsEnhancedMode === 'fake-ip' ? 'fake-ip' : null;
        setText('nekocoffee-dns-summary', dnsModeLabel(runtimeDnsMode || settings.dnsMode));
        setText('nekocoffee-root', installation.root || '--');
        setText('nekocoffee-shell-version', installation.version || '--');
        setText('nekocoffee-pid', installation.pid || '--');

        if (!state.dirtyTraffic) {
            renderSelect(
                byId('nekocoffee-traffic-mode'),
                settings.trafficOptions,
                settings.trafficMode,
                trafficModeLabel
            );
        }
        if (!state.dirtyDns) {
            renderSelect(
                byId('nekocoffee-dns-mode'),
                settings.dnsOptions,
                settings.dnsMode,
                dnsModeLabel
            );
        }

        var controlButtons = document.querySelectorAll('[data-control]');
        for (var index = 0; index < controlButtons.length; index += 1) {
            var operation = controlButtons[index].getAttribute('data-control');
            controlButtons[index].disabled = !installation.detected
                || (operation === 'start' ? running : !running)
                || !hasGrant('service.control')
                || !hasGrant('shell.execute');
        }

        var proxyButtons = document.querySelectorAll('[data-proxy-mode]');
        for (var proxyIndex = 0; proxyIndex < proxyButtons.length; proxyIndex += 1) {
            var mode = proxyButtons[proxyIndex].getAttribute('data-proxy-mode');
            proxyButtons[proxyIndex].className = mode === runtime.proxyMode ? 'is-active' : '';
            proxyButtons[proxyIndex].disabled = !running
                || !runtime.controllerReady
                || !hasGrant('network.client')
                || !hasGrant('shell.execute');
        }

        byId('nekocoffee-traffic-mode').disabled = !installation.detected;
        byId('nekocoffee-dns-mode').disabled = !installation.detected;
        byId('nekocoffee-apply-settings').disabled = !installation.detected
            || !hasGrant('filesystem.write')
            || !hasGrant('service.control')
            || !hasGrant('shell.execute');
        byId('nekocoffee-check-ip').disabled = !hasGrant('system.read')
            || !hasGrant('filesystem.read')
            || !hasGrant('network.client')
            || !hasGrant('shell.execute');

        var dashboardButton = byId('nekocoffee-dashboard');
        dashboardButton.disabled = !dashboard.available;
        dashboardButton.setAttribute('data-url', dashboardUrl(dashboard) || '');
        var warning = byId('nekocoffee-dashboard-warning');
        warning.hidden = !dashboard.available || dashboard.secretSet;
        warning.textContent = warning.hidden ? '' : tr(
            'dashboardNoSecret',
            '控制面板当前未设置访问密钥，请仅在可信局域网中使用。'
        );

        if (state.busy) {
            var busyButtons = document.querySelectorAll('.nekocoffee-page button');
            for (var busyIndex = 0; busyIndex < busyButtons.length; busyIndex += 1) {
                busyButtons[busyIndex].disabled = true;
            }
            byId('nekocoffee-traffic-mode').disabled = true;
            byId('nekocoffee-dns-mode').disabled = true;
        }

        setConnection(running ? 'is-running' : 'is-stopped', tr('online', '状态已同步'));
    }

    function refresh(silent) {
        if (state.stopped || state.busy) return Promise.resolve();
        var expectedRevision = state.revision;
        return request('status', 'GET').then(function (data) {
            if (expectedRevision !== state.revision || state.busy) return;
            render(data);
            if (!silent) showMessage('');
        }).catch(function (error) {
            setConnection('is-error', tr('connectionError', '连接异常'));
            if (!silent) showMessage(error.message, true);
        });
    }

    function scheduleRefresh() {
        if (state.timer) window.clearTimeout(state.timer);
        if (state.stopped) return;
        state.timer = window.setTimeout(function poll() {
            refresh(true).then(scheduleRefresh);
        }, document.hidden ? (config.interval || 5000) * 3 : (config.interval || 5000));
    }

    function runMutation(action, payload, successMessage, onSuccess) {
        state.revision += 1;
        setBusy(true);
        showMessage(tr('operationRunning', '正在执行操作…'));
        return request(action, 'POST', payload).then(function (data) {
            state.data = data;
            if (onSuccess) onSuccess(data);
            showMessage(successMessage || tr('operationComplete', '操作已完成。'));
        }).catch(function (error) {
            showMessage(error.message, true);
        }).then(function () {
            setBusy(false);
            return refresh(true);
        });
    }

    function bindEvents() {
        var controlButtons = document.querySelectorAll('[data-control]');
        for (var index = 0; index < controlButtons.length; index += 1) {
            controlButtons[index].onclick = function () {
                var operation = this.getAttribute('data-control');
                if (operation === 'stop' && !window.confirm(tr(
                    'confirmStop',
                    '停止后局域网设备的代理连接会中断，确定继续？'
                ))) return;
                if (operation === 'restart' && !window.confirm(tr(
                    'confirmRestart',
                    '重启期间代理连接会短暂中断，确定继续？'
                ))) return;
                runMutation('control', { operation: operation });
            };
        }

        var proxyButtons = document.querySelectorAll('[data-proxy-mode]');
        for (var proxyIndex = 0; proxyIndex < proxyButtons.length; proxyIndex += 1) {
            proxyButtons[proxyIndex].onclick = function () {
                runMutation('proxy-mode', { mode: this.getAttribute('data-proxy-mode') });
            };
        }

        byId('nekocoffee-apply-settings').onclick = function () {
            var trafficMode = byId('nekocoffee-traffic-mode').value;
            var dnsMode = byId('nekocoffee-dns-mode').value;
            var previous = state.data && state.data.settings ? state.data.settings : {};
            if (trafficMode === previous.trafficMode && dnsMode === previous.dnsMode) {
                state.dirtyTraffic = false;
                state.dirtyDns = false;
                if (state.data) render(state.data);
                showMessage(tr('settingsSaved', '设置已保存。'));
                return;
            }
            if (state.data && state.data.installation && state.data.installation.running
                && !window.confirm(tr(
                    'confirmApplyRestart',
                    '应用模式设置会重启正在运行的服务，确定继续？'
                ))) return;
            runMutation('settings', {
                trafficMode: trafficMode,
                dnsMode: dnsMode
            }, tr('settingsSaved', '设置已保存。'), function () {
                state.dirtyTraffic = false;
                state.dirtyDns = false;
            });
        };

        byId('nekocoffee-traffic-mode').onchange = function () {
            state.dirtyTraffic = true;
        };
        byId('nekocoffee-dns-mode').onchange = function () {
            state.dirtyDns = true;
        };

        byId('nekocoffee-dashboard').onclick = function () {
            var url = this.getAttribute('data-url');
            if (!url) return;
            var link = document.createElement('a');
            link.href = url;
            link.target = '_blank';
            link.rel = 'noopener noreferrer';
            link.style.display = 'none';
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
        };

        byId('nekocoffee-check-ip').onclick = function () {
            setBusy(true);
            setText('nekocoffee-direct-note', tr('connecting', '正在连接'));
            setText('nekocoffee-proxy-note', tr('connecting', '正在连接'));
            request('ip-check', 'POST', {}).then(function (data) {
                var result = data.ip || {};
                setText('nekocoffee-direct-ip', result.direct || '--');
                setText('nekocoffee-proxy-ip', result.proxy || '--');
                var stamp = result.timestamp ? new Date(result.timestamp * 1000).toLocaleTimeString() : '--';
                setText('nekocoffee-direct-note', result.direct
                    ? tr('detectedAt', '检测时间') + ' ' + stamp
                    : tr('unavailable', '暂不可用'));
                setText('nekocoffee-proxy-note', result.proxy
                    ? tr('detectedAt', '检测时间') + ' ' + stamp
                    : tr('unavailable', '暂不可用'));
                showMessage('');
            }).catch(function (error) {
                setText('nekocoffee-direct-note', tr('unavailable', '暂不可用'));
                setText('nekocoffee-proxy-note', tr('unavailable', '暂不可用'));
                showMessage(error.message, true);
            }).then(function () {
                setBusy(false);
            });
        };
    }

    function loadTranslations() {
        return new Promise(function (resolve) {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', config.i18nUrl, true);
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== 4) return;
                if (xhr.status >= 200 && xhr.status < 300) {
                    try { state.i18n = JSON.parse(xhr.responseText) || {}; } catch (error) {}
                }
                applyTranslations();
                resolve();
            };
            xhr.onerror = function () { resolve(); };
            xhr.send(null);
        });
    }

    document.addEventListener('visibilitychange', function () {
        if (!document.hidden && !state.busy) {
            if (state.timer) window.clearTimeout(state.timer);
            refresh(true).then(scheduleRefresh);
        }
    });
    window.addEventListener('beforeunload', function () {
        state.stopped = true;
        if (state.timer) window.clearTimeout(state.timer);
    });

    bindEvents();
    loadTranslations().then(function () {
        return refresh(false);
    }).then(scheduleRefresh);
}());
