/**
 * Install the built GL-AI assistant onto a live router for development.
 *
 * This is the fast iteration loop (direct file push). End users install the
 * .ipk / .apk instead, which performs the same steps via postinst.
 *
 * Deliberately does NOT restart nginx: the RPC object is loaded fresh from disk
 * per request, the view bundle and i18n files are static, and the menu entry is
 * read per request by ui.get_menu_list. Only the gl_home.html injection needs a
 * browser reload, not a server action.
 *
 *   node scripts/deploy.js
 *   node scripts/deploy.js --uninstall
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { gzipFile } = require('./lib/gzip');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'package/data');

const HOST = process.env.GL_HOST || '192.168.8.1';
const USER = process.env.GL_USER || 'root';
const PASS = process.env.GL_PASSWORD || 'Test@2026888';
const HOSTKEY =
    process.env.GL_HOSTKEY ||
    'SHA256:4lMbv4crd0mR02ngHvJcRTtZBCy1Qw6uhvrPVypE7YI';

const VIEW = 'gl-ai';
const PKG = 'gl-ai-agent';

function tool(name, fallback) {
    for (const c of [fallback, `D:\\SoftWares\\PuTTY\\${name}.exe`, name]) {
        if (!c) continue;
        if (c.includes('\\')) {
            if (fs.existsSync(c)) return c;
        } else {
            try {
                execFileSync(c, ['-V'], { stdio: 'ignore' });
                return c;
            } catch (e) {
                /* keep looking */
            }
        }
    }
    throw new Error(`cannot find ${name}; install PuTTY or add it to PATH`);
}

const PSCP = tool('pscp');
const PLINK = tool('plink');

function scp(local, remote) {
    execFileSync(
        PSCP,
        ['-scp', '-batch', '-hostkey', HOSTKEY, '-pw', PASS, local, `${USER}@${HOST}:${remote}`],
        { stdio: ['ignore', 'ignore', 'pipe'] }
    );
    console.log(`  -> ${remote}`);
}

function ssh(script) {
    return execFileSync(
        PLINK,
        ['-ssh', '-batch', '-hostkey', HOSTKEY, '-pw', PASS, `${USER}@${HOST}`, script],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
    );
}

function deploy() {
    const bundleBase = path.join(DATA, `www/views/gl-sdk4-ui-${VIEW}.common.js`);
    if (!fs.existsSync(bundleBase)) {
        throw new Error(`${bundleBase} missing - run: node scripts/build-ui.js`);
    }
    if (!fs.existsSync(bundleBase + '.gz')) gzipFile(bundleBase);
    console.log(
        `UI bundle ${(fs.statSync(bundleBase).size / 1024).toFixed(1)} KB ` +
        `-> gz ${(fs.statSync(bundleBase + '.gz').size / 1024).toFixed(1)} KB`
    );

    console.log('ensuring directories');
    ssh(
        [
            'mkdir -p /usr/lib/lua/glai /usr/share/gl-validator.d',
            'mkdir -p /usr/share/oui/menu.d /www/views /www/i18n /www/js',
            'mkdir -p /etc/gl-ai-agent/sessions',
        ].join('; ')
    );

    console.log('uploading backend');
    for (const f of fs.readdirSync(path.join(DATA, 'usr/lib/lua/glai'))) {
        scp(path.join(DATA, 'usr/lib/lua/glai', f), `/usr/lib/lua/glai/${f}`);
    }
    scp(path.join(DATA, 'usr/lib/oui-httpd/rpc/gl_ai'), '/usr/lib/oui-httpd/rpc/gl_ai');
    scp(path.join(DATA, 'usr/share/gl-validator.d/gl_ai.lua'), '/usr/share/gl-validator.d/gl_ai.lua');

    console.log('uploading UI');
    scp(bundleBase, `/www/views/gl-sdk4-ui-${VIEW}.common.js`);
    scp(bundleBase + '.gz', `/www/views/gl-sdk4-ui-${VIEW}.common.js.gz`);
    scp(path.join(DATA, `usr/share/oui/menu.d/${VIEW}.json`), `/usr/share/oui/menu.d/${VIEW}.json`);
    scp(path.join(DATA, `www/js/${PKG}-boot.js`), `/www/js/${PKG}-boot.js`);

    const i18nDir = path.join(DATA, 'www/i18n');
    for (const f of fs.readdirSync(i18nDir)) {
        if (f.startsWith(`gl-sdk4-ui-${VIEW}.`)) scp(path.join(i18nDir, f), `/www/i18n/${f}`);
    }

    console.log('activating');
    console.log(
        ssh(
            [
                'chmod 755 /usr/lib/oui-httpd/rpc/gl_ai',
                'chmod 644 /usr/share/gl-validator.d/gl_ai.lua',
                `chmod 644 /www/views/gl-sdk4-ui-${VIEW}.common.js /www/views/gl-sdk4-ui-${VIEW}.common.js.gz`,
                // inject the bootstrap before the SPA bundle, idempotently
                `grep -q '${PKG}-boot' /www/gl_home.html 2>/dev/null || ` +
                    `sed -i 's#<script src="/js/app\\.#<script src="/js/${PKG}-boot.js"></script><script src="/js/app.#' /www/gl_home.html`,
                `echo -n "  view:      "; curl -s -o /dev/null -w "%{http_code}\\n" http://127.0.0.1/views/gl-sdk4-ui-${VIEW}.common.js`,
                `echo -n "  boot js:   "; curl -s -o /dev/null -w "%{http_code}\\n" http://127.0.0.1/js/${PKG}-boot.js`,
                `echo -n "  injection: "; grep -c '${PKG}-boot' /www/gl_home.html`,
                'echo -n "  menu file: "; ls /usr/share/oui/menu.d/gl-ai.json >/dev/null 2>&1 && echo present || echo MISSING',
                'echo -n "  i18n files: "; ls /www/i18n/gl-sdk4-ui-gl-ai.*.json 2>/dev/null | wc -l',
            ].join('; ')
        )
    );
}

function uninstall() {
    console.log(`uninstalling from ${HOST}`);
    console.log(
        ssh(
            [
                `sed -i 's#<script src="/js/${PKG}-boot.js"></script>##g' /www/gl_home.html`,
                `rm -f /www/views/gl-sdk4-ui-${VIEW}.common.js /www/views/gl-sdk4-ui-${VIEW}.common.js.gz`,
                `rm -f /www/js/${PKG}-boot.js`,
                'rm -f /usr/share/oui/menu.d/gl-ai.json',
                `rm -f /www/i18n/gl-sdk4-ui-${VIEW}.*.json`,
                'rm -f /usr/lib/oui-httpd/rpc/gl_ai',
                'rm -f /usr/share/gl-validator.d/gl_ai.lua',
                'rm -rf /usr/lib/lua/glai /etc/gl-ai-agent',
                'echo -n "  injection left: "; grep -c "gl-ai-agent-boot" /www/gl_home.html || true',
                'echo -n "  view left:      "; ls /www/views/gl-sdk4-ui-gl-ai.common.js 2>/dev/null | wc -l',
                'echo -n "  menu left:      "; ls /usr/share/oui/menu.d/gl-ai.json 2>/dev/null | wc -l',
                'echo -n "  rpc left:       "; ls /usr/lib/oui-httpd/rpc/gl_ai 2>/dev/null | wc -l',
            ].join('; ')
        )
    );
}

try {
    if (process.argv.includes('--uninstall')) uninstall();
    else deploy();
} catch (e) {
    console.error(String((e.stderr || '') + (e.stdout || '') || e.message));
    process.exit(1);
}
