/**
 * Check whether a plain page (i.e. the GL admin page) provides a `module`
 * shim, and whether our bundle evaluates to a usable component there.
 *
 *   node scripts/check-eval-contract.js
 */
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '..');
const BUNDLE = path.join(ROOT, 'package/data/www/views/gl-sdk4-ui-gl-ai.common.js');
const PAGE = path.join(ROOT, 'deploy/probe/eval-contract.html');
const PORT = Number(process.env.PROBE_PORT || 8899);

function findBrowser() {
    const c = [
        process.env.GL_BROWSER,
        'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
        'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
        process.env.LOCALAPPDATA + '\\Google\\Chrome\\Application\\chrome.exe',
    ].filter(Boolean);
    for (const p of c) if (fs.existsSync(p)) return p;
    return undefined;
}

const server = http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/' || url === '/index.html') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(fs.readFileSync(PAGE));
    } else if (url === '/bundle.js') {
        res.writeHead(200, { 'Content-Type': 'application/javascript' });
        res.end(fs.readFileSync(BUNDLE));
    } else {
        res.writeHead(404).end('nope');
    }
});

server.listen(PORT, '127.0.0.1', async () => {
    const browser = await chromium.launch({
        headless: true,
        executablePath: findBrowser(),
        args: ['--no-sandbox'],
    });
    const page = await browser.newPage();
    const consoleMsgs = [];
    page.on('console', (m) => consoleMsgs.push(`[${m.type()}] ${m.text()}`));
    page.on('pageerror', (e) => consoleMsgs.push(`[pageerror] ${e}`));

    await page.goto(`http://127.0.0.1:${PORT}/`, { waitUntil: 'networkidle' });
    await page.waitForTimeout(1500);

    const text = await page.locator('#out').innerText();
    const summary = await page.locator('#summary').textContent().catch(() => '{}');

    console.log(text.replace(/<[^>]+>/g, ''));
    console.log('\n== browser console ==');
    consoleMsgs.forEach((m) => console.log('  ' + m));
    console.log('\n== summary ==');
    console.log('  ' + summary);

    await browser.close();
    server.close();
});
