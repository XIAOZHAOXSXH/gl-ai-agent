/**
 * Leave the device in a neutral state between sessions.
 *
 * Clears runtime scratch (turn state, event logs, pending approvals, locks) and
 * reports the things worth knowing before the next run: which config is stored,
 * whether the router's own WiFi is untouched, and whether the service tier is
 * healthy. It changes nothing outside /tmp/gl-ai-agent.
 *
 *   node scripts/reset-device.js
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const HOST = process.env.GL_HOST || '192.168.8.1';
const USER = process.env.GL_USER || 'root';
const PASS = process.env.GL_PASSWORD || 'Test@2026888';
const HOSTKEY = process.env.GL_HOSTKEY || 'SHA256:4lMbv4crd0mR02ngHvJcRTtZBCy1Qw6uhvrPVypE7YI';

const PLINK = fs.existsSync('D:\\SoftWares\\PuTTY\\plink.exe')
    ? 'D:\\SoftWares\\PuTTY\\plink.exe'
    : 'plink';

const script = [
    'echo "--- clearing runtime scratch ---"',
    'rm -rf /tmp/gl-ai-agent',
    'echo "  /tmp/gl-ai-agent removed"',

    'echo "--- stored provider config (key masked) ---"',
    `sed 's/"api_key":"[^"]*"/"api_key":"***"/' /etc/gl-ai-agent/config.json 2>/dev/null || echo "  (none)"`,

    'echo "--- router WiFi untouched? ---"',
    'echo -n "  2.4G main SSID: "; uci get wireless.default_radio0.ssid',
    'if uci show wireless | grep -q "GL-Test-2G"; then echo "  LEAKED: GL-Test-2G present"; else echo "  clean: no test SSID"; fi',

    'echo "--- service tier health ---"',
    'echo -n "  ubus objects: "; ubus list 2>/dev/null | wc -l',
    'echo -n "  ujail crashes: "; dmesg | grep -c "SIGSEGV to ujail"',
    'echo -n "  nginx: "; curl -s -o /dev/null -w "%{http_code}\\n" http://127.0.0.1/gl_home.html',

    'echo "--- plugin surface ---"',
    'echo -n "  view: "; curl -s -o /dev/null -w "%{http_code}\\n" http://127.0.0.1/views/gl-sdk4-ui-gl-ai.common.js',
    'echo -n "  injection: "; grep -c "gl-ai-agent-boot" /www/gl_home.html',
    'echo -n "  menu entry: "; ls /usr/share/oui/menu.d/gl-ai.json >/dev/null 2>&1 && echo present || echo MISSING',
    'echo -n "  nginx conf added by us: "; ls /etc/nginx/gl-conf.d/gl-ai-agent.conf 2>/dev/null | wc -l',
].join('; ');

try {
    console.log(`resetting ${HOST}\n`);
    console.log(
        execFileSync(
            PLINK,
            ['-ssh', '-batch', '-hostkey', HOSTKEY, '-pw', PASS, `${USER}@${HOST}`, script],
            { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
        )
    );
} catch (e) {
    console.error(String((e.stderr || '') + (e.stdout || '') || e.message));
    process.exit(1);
}
