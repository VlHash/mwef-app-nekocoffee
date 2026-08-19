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
        dirtyDns: false,
        dirtyIpv6: false,
        dirtyQuic: false
    };

    function byId(id) { return document.getElementById(id); }
    function tr(key, fallback) { return state.i18n[key] || fallback || key; }

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

    function isFormData(value) {
        return typeof window.FormData !== 'undefined' && value instanceof window.FormData;
    }

    function request(action, method, payload) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            xhr.open(method || 'GET', config.apiUrl + '?action=' + encodeURIComponent(action), true);
            xhr.timeout = action === 'profile-switch' ? 60000
                : action === 'ip-check' ? 55000
                : action === 'profile-import' || action === 'profile-upload' ? 40000 : 25000;
            xhr.setRequestHeader('Accept', 'application/json');
            if (payload && !isFormData(payload)) {
                xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
                payload = encode(payload);
            }
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== 4) return;
                var data;
                try { data = JSON.parse(xhr.responseText); } catch (error) {
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

    function hasGrants(permissions) {
        for (var index = 0; index < permissions.length; index += 1) {
            if (!hasGrant(permissions[index])) return false;
        }
        return true;
    }

    function syncBeautifiedSelect(select) {
        if (!select) return;
        var jq = window.jQuery || window.$;
        if (jq && typeof jq.selectBeautify === 'function' && !jq(select).siblings('.textContent').length) {
            jq.selectBeautify({ container: '#nekocoffee-mode-settings' });
        }
        var dummy = select.parentNode && select.parentNode.querySelector('.textContent .dummy');
        var option = select.options[select.selectedIndex];
        if (dummy && option) dummy.textContent = option.textContent || option.innerText || '';
    }

    function setSelectDisabled(select, disabled) {
        if (!select) return;
        select.disabled = disabled;
        var wrapper = select.parentNode;
        if (wrapper) wrapper.className = 'v mwef-native-select' + (disabled ? ' is-disabled' : '');
    }

    function setBusy(busy) {
        state.busy = busy;
        if (state.data) render(state.data);
    }

    function proxyModeLabel(value) {
        var labels = {
            rule: tr('ruleMode', '规则'),
            global: tr('globalMode', '全局'),
            direct: tr('directMode', '直连')
        };
        return labels[String(value || '').toLowerCase()] || '--';
    }

    function dnsModeLabel(value) {
        var labels = {
            redir_host: tr('modeRedirectHost', 'redirect-host（兼容）'),
            'fake-ip': tr('modeFakeIp', 'fake-ip（增强）'),
            mix: tr('modeDnsMix', 'mix（Neko 管理器兼容）'),
            route: tr('modeDnsRoute', 'route（Neko 管理器兼容）')
        };
        return labels[value] || value || '--';
    }

    function dashboardUrl(details) {
        if (!details || !details.port) return null;
        var host = window.location.hostname || window.location.host.split(':')[0];
        if (host.indexOf(':') >= 0 && host.charAt(0) !== '[') host = '[' + host + ']';
        var path = details.path || '/ui/';
        if (path.charAt(0) !== '/') path = '/' + path;
        return 'http://' + host + ':' + details.port + path;
    }

    function formatSize(size) {
        size = Number(size) || 0;
        if (size < 1024) return size + ' B';
        if (size < 1024 * 1024) return (size / 1024).toFixed(1) + ' KiB';
        return (size / 1024 / 1024).toFixed(2) + ' MiB';
    }

    function formatDate(timestamp) {
        if (!timestamp) return '--';
        try { return new Date(timestamp * 1000).toLocaleString(); } catch (error) { return '--'; }
    }

    function renderProfiles(profiles, installation) {
        var body = byId('nekocoffee-profile-list');
        while (body.firstChild) body.removeChild(body.firstChild);
        profiles = profiles || [];
        if (!profiles.length) {
            var emptyRow = document.createElement('tr');
            var emptyCell = document.createElement('td');
            emptyCell.colSpan = 5;
            emptyCell.className = 'nekocoffee-empty';
            emptyCell.textContent = tr('noProfiles', '未找到可用配置文件');
            emptyRow.appendChild(emptyCell);
            body.appendChild(emptyRow);
            return;
        }
        var canSwitch = hasGrants([
            'system.read', 'filesystem.read', 'filesystem.write', 'network.client', 'service.control', 'shell.execute'
        ]);
        profiles.forEach(function (profile) {
            var row = document.createElement('tr');
            var name = document.createElement('td');
            var nameCode = document.createElement('code');
            nameCode.textContent = profile.name;
            name.appendChild(nameCode);
            var size = document.createElement('td');
            size.textContent = formatSize(profile.size);
            var modified = document.createElement('td');
            modified.textContent = formatDate(profile.modified);
            var status = document.createElement('td');
            status.className = profile.active ? 'is-active-profile' : '';
            status.textContent = profile.active ? tr('activeProfile', '当前使用') : tr('availableProfile', '可用');
            var action = document.createElement('td');
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'mwef-btn mwef-btn-small';
            button.setAttribute('data-profile-name', profile.name);
            button.textContent = profile.active ? tr('active', '已启用') : tr('switchProfile', '切换');
            button.disabled = profile.active || !canSwitch || state.busy || !installation.detected;
            action.appendChild(button);
            row.appendChild(name);
            row.appendChild(size);
            row.appendChild(modified);
            row.appendChild(status);
            row.appendChild(action);
            body.appendChild(row);
        });
    }

    function render(data) {
        state.data = data;
        var installation = data.installation || {};
        var runtime = data.runtime || {};
        var settings = data.settings || {};
        var dashboard = data.dashboard || {};
        var running = installation.running === true;
        var installed = installation.detected === true;

        setText('nekocoffee-installation', installed
            ? (installation.name || 'ShellClash') + ' ' + (installation.version || '')
            : (data.permissionMissing && data.permissionMissing.length
                ? tr('permissionMissing', '缺少所需插件权限，请在框架设置中授权。')
                : tr('notInstalled', '未找到兼容的 Neko 运行环境')));
        setText('nekocoffee-service-state', installed
            ? (running ? tr('running', '运行中') : tr('stopped', '已停止')) : '--');
        byId('nekocoffee-service-state').className = running ? 'is-running' : 'is-stopped';
        setText('nekocoffee-core-version', installation.coreVersion || installation.core || '--');
        setText('nekocoffee-proxy-mode', proxyModeLabel(runtime.proxyMode));
        var runtimeDnsMode = runtime.dnsEnhancedMode === 'redir-host'
            ? 'redir_host' : runtime.dnsEnhancedMode === 'fake-ip' ? 'fake-ip' : null;
        setText('nekocoffee-dns-summary', dnsModeLabel(runtimeDnsMode || settings.dnsMode));
        setText('nekocoffee-root', installation.root || '--');
        setText('nekocoffee-shell-version', installation.version || '--');
        setText('nekocoffee-pid', installation.pid || '--');

        var trafficSelect = byId('nekocoffee-traffic-mode');
        var dnsSelect = byId('nekocoffee-dns-mode');
        var canEditSettings = installed && hasGrants([
            'system.read', 'filesystem.read', 'filesystem.write', 'service.control', 'shell.execute'
        ]);
        if (!state.dirtyTraffic && settings.trafficMode) trafficSelect.value = settings.trafficMode;
        if (!state.dirtyDns && settings.dnsMode) dnsSelect.value = settings.dnsMode;
        setSelectDisabled(trafficSelect, !canEditSettings || state.busy);
        setSelectDisabled(dnsSelect, !canEditSettings || state.busy);
        syncBeautifiedSelect(trafficSelect);
        syncBeautifiedSelect(dnsSelect);

        var ipv6 = byId('nekocoffee-ipv6-proxy');
        var quic = byId('nekocoffee-quic-proxy');
        if (!state.dirtyIpv6) ipv6.checked = settings.ipv6Proxy === true;
        if (!state.dirtyQuic) quic.checked = settings.quicProxy !== false;
        ipv6.disabled = !canEditSettings || state.busy;
        quic.disabled = !canEditSettings || state.busy;
        setText('nekocoffee-ipv6-proxy-state', ipv6.checked ? tr('enabled', '已启用') : tr('disabled', '已关闭'));
        setText('nekocoffee-quic-proxy-state', quic.checked ? tr('enabled', '已启用') : tr('disabled', '已关闭'));

        var controlButtons = document.querySelectorAll('[data-control]');
        for (var index = 0; index < controlButtons.length; index += 1) {
            var operation = controlButtons[index].getAttribute('data-control');
            controlButtons[index].disabled = state.busy || !installed
                || (operation === 'start' ? running : !running)
                || !hasGrants(['system.read', 'filesystem.read', 'service.control', 'shell.execute']);
        }

        var proxyButtons = document.querySelectorAll('[data-proxy-mode]');
        for (var proxyIndex = 0; proxyIndex < proxyButtons.length; proxyIndex += 1) {
            var mode = proxyButtons[proxyIndex].getAttribute('data-proxy-mode');
            proxyButtons[proxyIndex].className = mode === runtime.proxyMode ? 'is-active' : '';
            proxyButtons[proxyIndex].disabled = state.busy || !running || !runtime.controllerReady
                || !hasGrants(['network.client', 'shell.execute']);
        }

        byId('nekocoffee-apply-settings').disabled = state.busy || !canEditSettings;
        byId('nekocoffee-check-ip').disabled = state.busy || !hasGrants([
            'system.read', 'filesystem.read', 'network.client', 'shell.execute'
        ]);

        var canAddProfile = installed && hasGrants(['system.read', 'filesystem.read', 'filesystem.write']);
        byId('nekocoffee-choose-config').disabled = state.busy || !canAddProfile;
        byId('nekocoffee-upload-config').disabled = state.busy || !canAddProfile || !byId('nekocoffee-config-file').files.length;
        byId('nekocoffee-config-file').disabled = state.busy || !canAddProfile;
        var canImport = canAddProfile && hasGrants(['network.client', 'shell.execute']);
        byId('nekocoffee-import-url').disabled = state.busy || !canImport;
        byId('nekocoffee-import-name').disabled = state.busy || !canImport;
        byId('nekocoffee-import-config').disabled = state.busy || !canImport;
        renderProfiles(data.profiles, installation);

        var dashboardButton = byId('nekocoffee-dashboard');
        dashboardButton.disabled = state.busy || !dashboard.available;
        dashboardButton.setAttribute('data-url', dashboardUrl(dashboard) || '');
        var warning = byId('nekocoffee-dashboard-warning');
        warning.hidden = !dashboard.available || dashboard.secretSet;
        warning.textContent = warning.hidden ? '' : tr(
            'dashboardNoSecret', '控制面板当前未设置访问密钥，请仅在可信局域网中使用。'
        );

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

    function resetSettingDirty() {
        state.dirtyTraffic = false;
        state.dirtyDns = false;
        state.dirtyIpv6 = false;
        state.dirtyQuic = false;
    }

    function bindEvents() {
        var controlButtons = document.querySelectorAll('[data-control]');
        for (var index = 0; index < controlButtons.length; index += 1) {
            controlButtons[index].onclick = function () {
                var operation = this.getAttribute('data-control');
                if (operation === 'stop' && !window.confirm(tr('confirmStop', '停止后局域网设备的代理连接会中断，确定继续？'))) return;
                if (operation === 'restart' && !window.confirm(tr('confirmRestart', '重启期间代理连接会短暂中断，确定继续？'))) return;
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
            var ipv6Proxy = byId('nekocoffee-ipv6-proxy').checked;
            var quicProxy = byId('nekocoffee-quic-proxy').checked;
            var previous = state.data && state.data.settings ? state.data.settings : {};
            var runtimeDns = state.data && state.data.runtime ? state.data.runtime.dnsEnhancedMode : null;
            var expectedRuntimeDns = dnsMode === 'redir_host' ? 'redir-host' : dnsMode === 'fake-ip' ? 'fake-ip' : null;
            if (trafficMode === previous.trafficMode && dnsMode === previous.dnsMode
                && ipv6Proxy === previous.ipv6Proxy && quicProxy === previous.quicProxy
                && (!expectedRuntimeDns || !runtimeDns || expectedRuntimeDns === runtimeDns)) {
                resetSettingDirty();
                if (state.data) render(state.data);
                showMessage(tr('settingsSaved', '设置已保存。'));
                return;
            }
            if (state.data && state.data.installation && state.data.installation.running
                && !window.confirm(tr('confirmApplyRestart', '应用模式设置会重启正在运行的服务，确定继续？'))) return;
            runMutation('settings', {
                trafficMode: trafficMode,
                dnsMode: dnsMode,
                ipv6Proxy: ipv6Proxy ? '1' : '0',
                quicProxy: quicProxy ? '1' : '0'
            }, tr('settingsSaved', '设置已保存。'), resetSettingDirty);
        };

        byId('nekocoffee-traffic-mode').onchange = function () {
            state.dirtyTraffic = true;
            syncBeautifiedSelect(this);
        };
        byId('nekocoffee-dns-mode').onchange = function () {
            state.dirtyDns = true;
            syncBeautifiedSelect(this);
        };
        byId('nekocoffee-ipv6-proxy').onchange = function () {
            state.dirtyIpv6 = true;
            setText('nekocoffee-ipv6-proxy-state', this.checked ? tr('enabled', '已启用') : tr('disabled', '已关闭'));
        };
        byId('nekocoffee-quic-proxy').onchange = function () {
            state.dirtyQuic = true;
            setText('nekocoffee-quic-proxy-state', this.checked ? tr('enabled', '已启用') : tr('disabled', '已关闭'));
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
                var direct = result.direct || {};
                var proxy = result.proxy || {};
                var stamp = result.timestamp ? new Date(result.timestamp * 1000).toLocaleTimeString() : '--';
                setText('nekocoffee-direct-ip', direct.ip || '--');
                setText('nekocoffee-proxy-ip', proxy.ip || '--');
                setText('nekocoffee-direct-note', direct.ip
                    ? (direct.source || '') + ' · ' + tr('detectedAt', '检测时间') + ' ' + stamp
                    : tr('unavailable', '暂不可用'));
                setText('nekocoffee-proxy-note', proxy.ip
                    ? (proxy.source || '') + ' · ' + tr('detectedAt', '检测时间') + ' ' + stamp
                    : tr('unavailable', '暂不可用'));
                if (!direct.ip && !proxy.ip) showMessage(tr('ipCheckFailed', '所有出口 IP 检测源均不可用。'), true);
                else showMessage('');
            }).catch(function (error) {
                setText('nekocoffee-direct-note', tr('unavailable', '暂不可用'));
                setText('nekocoffee-proxy-note', tr('unavailable', '暂不可用'));
                showMessage(error.message, true);
            }).then(function () { setBusy(false); });
        };

        byId('nekocoffee-choose-config').onclick = function () { byId('nekocoffee-config-file').click(); };
        byId('nekocoffee-config-file').onchange = function () {
            var file = this.files && this.files[0];
            byId('nekocoffee-selected-file').textContent = file ? file.name : tr('noFileSelected', '未选择文件');
            if (state.data) render(state.data);
        };
        byId('nekocoffee-upload-config').onclick = function () {
            var input = byId('nekocoffee-config-file');
            var file = input.files && input.files[0];
            if (!file) return;
            var form = new window.FormData();
            form.append('configFile', file, file.name);
            runMutation('profile-upload', form, tr('uploadComplete', '配置文件已上传。'), function () {
                input.value = '';
                byId('nekocoffee-selected-file').textContent = tr('noFileSelected', '未选择文件');
            });
        };

        byId('nekocoffee-import-config').onclick = function () {
            var url = byId('nekocoffee-import-url').value.replace(/^\s+|\s+$/g, '');
            var name = byId('nekocoffee-import-name').value.replace(/^\s+|\s+$/g, '');
            if (!url || !name) {
                showMessage(tr('importFieldsRequired', '请输入 HTTPS 地址和以 .yaml/.yml 结尾的配置名称。'), true);
                return;
            }
            runMutation('profile-import', { url: url, profileName: name }, tr('importComplete', '配置文件已导入。'), function () {
                byId('nekocoffee-import-url').value = '';
                byId('nekocoffee-import-name').value = '';
            });
        };

        byId('nekocoffee-profile-list').onclick = function (event) {
            var target = event.target || event.srcElement;
            var name = target && target.getAttribute ? target.getAttribute('data-profile-name') : null;
            if (!name || target.disabled) return;
            var running = state.data && state.data.installation && state.data.installation.running;
            var message = running
                ? tr('confirmSwitchRestart', '切换配置会重启正在运行的服务，确定继续？')
                : tr('confirmSwitch', '确定切换到这个配置文件？');
            if (!window.confirm(message)) return;
            runMutation('profile-switch', { profileName: name }, tr('profileSwitched', '配置文件已切换。'));
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
    loadTranslations().then(function () { return refresh(false); }).then(scheduleRefresh);
}());
