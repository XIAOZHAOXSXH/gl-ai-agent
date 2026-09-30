/**
 * Full lifecycle test against a real router: install the built .ipk, verify
 * every surface it is supposed to create, then remove it and verify the stock
 * admin page is byte-identical to its original state.
 *
 *   node scripts/test-install.js
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const HOST = process.env.GL_HOST || '192.168.8.1';
const USER = process.env.GL_USER || 'root';
const PASS = process.env.GL_PASSWORD || 'Test@2026888';
const HOSTKEY = process.env.GL_HOSTKEY || 'SHA256:4lMbv4crd0mR02ngHvJcRTtZBCy1Qw6uhvrPVypE7YI';

const PSCP = fs.existsSync('D:\\SoftWares\\PuTTY\\pscp.exe')
    ? 'D:\\SoftWares\\PuTTY\\pscp.exe' : 'pscp';
const PLINK = fs.existsSync('D:\\SoftWares\\PuTTY\\plink.exe')
    ? 'D:\\SoftWares\\PuTTY\\plink.exe' : 'plink';

const ipk = fs.readdirSync(path.join(ROOT, 'dist')).find((f) => f.endsWith('.ipk'));
if (!ipk) {
    console.error('no .ipk in dist/ - run: node scripts/build-ipk.js');
    process.exit(1);
}
const IPK = path.join(ROOT, 'dist', ipk);

function scp(local, remote) {
    execFileSync(PSCP, ['-scp', '-batch', '-hostkey', HOSTKEY, '-pw', PASS, local, `${USER}@${HOST}:${remote}`],
        { stdio: ['ignore', 'ignore', 'pipe'] });
}
function ssh(script) {
    return execFileSync(PLINK, ['-ssh', '-batch', '-hostkey', HOSTKEY, '-pw', PASS, `${USER}@${HOST}`, script],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

const step = (t) => console.log(`\n===== ${t} =====`);

console.log(`installing ${ipk} on ${HOST}`);

step('0. baseline: make sure it is not installed, record stock page hash');
console.log(ssh([
    'opkg remove gl-ai-agent >/dev/null 2>&1 || true',
    'rm -f /etc/gl-ai-agent/gl_home.html.orig',
    'echo -n "stock gl_home.html md5: "; md5sum /www/gl_home.html | cut -d" " -f1',
    'echo -n "inject tag present: "; grep -c "gl-ai-agent-boot" /www/gl_home.html || true',
].join('; ')));

step('1. install the package');
scp(IPK, `/tmp/${ipk}`);
console.log(ssh(`opkg install --force-reinstall /tmp/${ipk} 2>&1`));

step('2. verify every installed surface');
console.log(ssh([
    'echo "--- files ---"',
    'for f in /www/views/gl-sdk4-ui-gl-ai.common.js \\',
    '         /www/views/gl-sdk4-ui-gl-ai.common.js.gz \\',
    '         /usr/share/oui/menu.d/gl-ai.json \\',
    '         /usr/lib/oui-httpd/rpc/gl_ai \\',
    '         /usr/share/gl-validator.d/gl_ai.lua \\',
    '         /www/js/gl-ai-agent-boot.js; do',
    '  [ -e "$f" ] && echo "  OK   $f" || echo "  MISS $f"',
    'done',
    'echo -n "  i18n files: "; ls /www/i18n/gl-sdk4-ui-gl-ai.*.json 2>/dev/null | wc -l',
    // The agent deliberately adds no nginx location: streaming is delivered by
    // polling the RPC object, so install/upgrade never touches the web server.
    'echo -n "  nginx conf added by us: "; ls /etc/nginx/gl-conf.d/gl-ai-agent.conf 2>/dev/null | wc -l',
    'echo "--- injection ---"',
    'echo -n "  boot tag in page: "; grep -c "gl-ai-agent-boot" /www/gl_home.html || true',
    'echo "--- serving ---"',
    'echo -n "  view js: "; curl -s -o /dev/null -w "%{http_code} %{content_type} %{size_download}\\n" http://127.0.0.1/views/gl-sdk4-ui-gl-ai.common.js',
    'echo -n "  boot js: "; curl -s -o /dev/null -w "%{http_code}\\n" http://127.0.0.1/js/gl-ai-agent-boot.js',
    'echo -n "  nginx config: "; nginx -t 2>&1 | tail -1',
    'echo -n "  ubus objects: "; ubus list 2>/dev/null | wc -l',
    'echo "--- rpc ---"',
    'printf \'%s\' \'{"jsonrpc":"2.0","method":"call","params":["","gl_ai","get_config",{}],"id":1}\' > /tmp/q.json',
    'curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/q.json | head -c 130',
    'echo',
    'printf \'%s\' \'{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"selftest","p":{}}],"id":1}\' > /tmp/s.json',
    'echo -n "  tool selftest: "',
    'curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/s.json | grep -o \'"passed":[0-9]*\\|"failed":[0-9]*\' | tr "\\n" " "',
    'echo',
    'echo -n "  menu entry present: "',
    'printf \'%s\' \'{"jsonrpc":"2.0","method":"call","params":["","ui","get_menu_list",{}],"id":1}\' > /tmp/m.json',
    'curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/m.json | sed \'s/},{/}\\n{/g\' | grep -c \'gl-ai\'',
].join('\n')));

step('3. reinstall must be idempotent (no duplicate injection)');
console.log(ssh([
    `opkg install --force-reinstall /tmp/${ipk} >/dev/null 2>&1`,
    'echo -n "  boot tags now: "; grep -o "gl-ai-agent-boot" /www/gl_home.html | wc -l',
].join('; ')));

step('4. remove and verify a clean restore');
console.log(ssh([
    'opkg remove gl-ai-agent 2>&1 | tail -3',
    'echo -n "  stock page md5: "; md5sum /www/gl_home.html | cut -d" " -f1',
    'echo -n "  boot tag remaining: "; grep -c "gl-ai-agent-boot" /www/gl_home.html || true',
    'echo -n "  view file remaining: "; [ -e /www/views/gl-sdk4-ui-gl-ai.common.js ] && echo yes || echo no',
    'echo -n "  menu file remaining: "; [ -e /usr/share/oui/menu.d/gl-ai.json ] && echo yes || echo no',
    'echo -n "  rpc object remaining: "; [ -e /usr/lib/oui-httpd/rpc/gl_ai ] && echo yes || echo no',
    'echo -n "  nginx: "; nginx -t 2>&1 | tail -1',
].join('\n')));

console.log('\ndone.');
