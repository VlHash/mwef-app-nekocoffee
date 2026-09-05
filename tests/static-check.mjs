import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const tests = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(tests);
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const fail = (message) => { throw new Error(message); };

const manifest = JSON.parse(read('mwef-plugin.json'));
const translations = {
    en: JSON.parse(read('i18n/en.json')),
    'zh-CN': JSON.parse(read('i18n/zh-CN.json'))
};
const javascript = read('overlay/www/xqext/plugins/mwef-app-nekocoffee/nekocoffee.js');
const controller = read('overlay/luci/controller/api/mwef_nekocoffee.lua');
const templates = [
    ['router template', read('overlay/luci/view/web/xqext/nekocoffee.htm')],
    ['preview template', read('tests/preview.html')]
];

new Function(javascript);

const referencedIds = new Set(
    [...javascript.matchAll(/byId\('([^']+)'\)/g)].map((match) => match[1])
);
const translationKeys = new Set();

for (const [name, template] of templates) {
    const ids = [...template.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
    const uniqueIds = new Set(ids);
    if (uniqueIds.size !== ids.length) fail(`${name} contains duplicate element IDs`);
    for (const id of referencedIds) {
        if (!uniqueIds.has(id)) fail(`${name} is missing #${id}`);
    }
    for (const match of template.matchAll(/\bdata-i18n="([^"]+)"/g)) translationKeys.add(match[1]);
}
for (const match of javascript.matchAll(/tr\('([^']+)'/g)) translationKeys.add(match[1]);

for (const [language, values] of Object.entries(translations)) {
    for (const key of translationKeys) {
        if (!Object.prototype.hasOwnProperty.call(values, key)) {
            fail(`${language} translation is missing ${key}`);
        }
    }
}

if (!templates[0][1].match(/id="nekocoffee-device-panel"[^>]*\bhidden\b/)) {
    fail('LAN device panel must be collapsed by default');
}
if (!controller.includes('action == "device-policy"')
    || !controller.includes('macfilter_type = filter_type')
    || !controller.includes('/configs/mac')) {
    fail('Device policy backend wiring is incomplete');
}
if (!controller.includes(`local VERSION = "${manifest.version}"`)) {
    fail('Manifest and controller versions differ');
}
for (const permission of ['system.read', 'filesystem.read', 'filesystem.write', 'service.control', 'shell.execute']) {
    if (!manifest.permissions.includes(permission)) fail(`Manifest is missing ${permission}`);
}

console.log(`Static checks passed for NekoCoffee ${manifest.version} (${referencedIds.size} DOM IDs, ${translationKeys.size} translations).`);

