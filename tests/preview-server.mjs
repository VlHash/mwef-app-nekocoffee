import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const tests = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(tests);
const framework = path.join(path.dirname(root), 'routerui');
const assets = path.join(root, 'overlay', 'www', 'xqext', 'plugins', 'mwef-app-nekocoffee');
const port = Number(process.env.NEKOCOFFEE_PREVIEW_PORT || 4178);

const model = {
    code: 0,
    timestamp: Math.floor(Date.now() / 1000),
    grants: ['filesystem.read', 'filesystem.write', 'network.client', 'service.control', 'shell.execute', 'system.read'],
    installation: {
        detected: true,
        name: 'ShellCrash',
        root: '/data/other_vol/ShellCrash',
        version: '1.9.5beta3',
        core: 'meta',
        coreVersion: 'v1.19.17',
        running: true,
        pid: 1858
    },
    runtime: { proxyMode: 'rule', controllerReady: true, dnsEnhancedMode: 'redir-host' },
    settings: {
        trafficMode: 'Mix',
        dnsMode: 'redir_host',
        trafficOptions: ['Mix', 'Redir', 'Tproxy', 'Tun'],
        dnsOptions: ['redir_host', 'fake-ip'],
        mixedPort: 7890
    },
    dashboard: { available: true, port: 9999, path: '/ui/', secretSet: false }
};

const files = {
    '/': [path.join(tests, 'preview.html'), 'text/html; charset=utf-8'],
    '/core.css': [path.join(framework, 'router-overlay', 'www-upper', 'xqext', 'core.css'), 'text/css; charset=utf-8'],
    '/nekocoffee.css': [path.join(assets, 'nekocoffee.css'), 'text/css; charset=utf-8'],
    '/nekocoffee.js': [path.join(assets, 'nekocoffee.js'), 'application/javascript; charset=utf-8'],
    '/i18n.json': [path.join(root, 'i18n', 'zh-CN.json'), 'application/json; charset=utf-8']
};

function json(res, value) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(value));
}

function body(req) {
    return new Promise((resolve) => {
        let value = '';
        req.on('data', (chunk) => { value += chunk; });
        req.on('end', () => resolve(new URLSearchParams(value)));
    });
}

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    if (url.pathname === '/api') {
        const action = url.searchParams.get('action') || 'status';
        const form = req.method === 'POST' ? await body(req) : new URLSearchParams();
        if (action === 'control') {
            const operation = form.get('operation');
            model.installation.running = operation !== 'stop';
            model.dashboard.available = model.installation.running;
            model.runtime.controllerReady = model.installation.running;
            model.installation.pid = model.installation.running ? 1858 : null;
        } else if (action === 'proxy-mode') {
            model.runtime.proxyMode = form.get('mode');
        } else if (action === 'settings') {
            model.settings.trafficMode = form.get('trafficMode');
            model.settings.dnsMode = form.get('dnsMode');
            model.runtime.dnsEnhancedMode = model.settings.dnsMode === 'fake-ip' ? 'fake-ip' : 'redir-host';
        } else if (action === 'ip-check') {
            return json(res, { code: 0, ip: { direct: '198.51.100.23', proxy: '203.0.113.8', timestamp: Math.floor(Date.now() / 1000) } });
        }
        model.timestamp = Math.floor(Date.now() / 1000);
        return json(res, model);
    }

    const entry = files[url.pathname];
    if (!entry) {
        res.writeHead(404);
        return res.end('Not found');
    }
    res.writeHead(200, { 'Content-Type': entry[1] });
    fs.createReadStream(entry[0]).pipe(res);
});

server.listen(port, '127.0.0.1', () => {
    process.stdout.write(`NekoCoffee preview: http://127.0.0.1:${port}/\n`);
});
