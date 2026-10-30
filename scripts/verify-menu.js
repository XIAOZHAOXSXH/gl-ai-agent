/**
 * Verify the native sidebar renders our translated menu label (not the raw
 * menu_gl-ai key), including on a cold shell.
 *
 *   node scripts/verify-menu.js
 */
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const HOST = process.env.GL_HOST || '192.168.8.1';
const PASS = process.env.GL_PASSWORD;
if (!PASS) throw new Error('GL_PASSWORD is required for menu verification');
const OUT = path.resolve(__dirname, '../artifacts');
const PROXY = process.env.GL_PROXY || 'http://127.0.0.1:7890';
const NO_PROXY = '127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12';

function findBrowser() {
    for (const c of [
        process.env.GL_BROWSER,
        'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
        'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    ].filter(Boolean)) {
        if (fs.existsSync(c)) return c;
    }
    return undefined;
}

(async () => {
    fs.mkdirSync(OUT, { recursive: true });
    const base = `http://${HOST}`;
    const browser = await chromium.launch({
        headless: true,
        executablePath: findBrowser(),
        proxy: { server: PROXY, bypass: NO_PROXY },
        args: ['--no-sandbox'],
    });
    const page = await browser.newContext({
        ignoreHTTPSErrors: true,
        viewport: { width: 1500, height: 940 },
    }).then((c) => c.newPage());

    const i18nHits = [];
    page.on('response', (r) => {
        if (r.url().includes('gl-ai')) i18nHits.push(`${r.status()} ${r.url()}`);
    });

    await page.goto(`${base}/#/login`, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2500);
    const pwd = page.locator('input[type="password"]').first();
    if (await pwd.count()) {
        await pwd.fill(PASS);
        const btn = page.locator('.login-btn button, .login-btn .gl-button, button[type="submit"]').first();
        if (await btn.count()) await btn.click();
        else await pwd.press('Enter');
        await page.waitForTimeout(4500);
    }

    // Check the cold shell first. This catches the regression where the sidebar
    // shows the raw menu_gl_ai key until the view is opened once.
    await page.goto(`${base}/#/overview`, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3000);
    const readSidebar = () => page.evaluate(() => {
        const links = Array.from(document.querySelectorAll('a, li, span, div'));
        const hit = links
            .map((e) => (e.textContent || '').trim())
            .filter((t) => t.includes('GL-AI') || t.includes('menu_gl-ai') || t.includes('menu_gl_ai'));
        return Array.from(new Set(hit)).slice(0, 10);
    });
    const coldSidebar = await readSidebar();

    // Visit the agent page and then re-render the shell to verify the warm path.
    await page.goto(`${base}/#/gl-ai`, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3500);

    // Now re-render the shell (hash change) and inspect the sidebar.
    await page.goto(`${base}/#/overview`, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3000);

    const sidebar = await readSidebar();

    await page.screenshot({ path: path.join(OUT, 'menu-sidebar.png') });

    // Expand the 系统 group so the entry is on screen, then shoot again.
    const sys = page.locator('text=系统').first();
    if (await sys.count()) {
        await sys.click().catch(() => {});
        await page.waitForTimeout(800);
        await sys.click().catch(() => {});
        await page.waitForTimeout(1200);
    }
    await page.screenshot({ path: path.join(OUT, 'menu-sidebar-expanded.png') });

    const report = {
        sidebarMatches: sidebar,
        coldSidebarMatches: coldSidebar,
        translatesCorrectly: sidebar.some((t) => t.includes('GL-AI助手') || t.includes('GL-AI Assistant')),
        showsRawKey: sidebar.some((t) => t.includes('menu_gl-ai') || t.includes('menu_gl_ai')),
        coldShowsRawKey: coldSidebar.some((t) => t.includes('menu_gl-ai') || t.includes('menu_gl_ai')),
        glAiRequests: i18nHits,
    };
    fs.writeFileSync(path.join(OUT, 'menu-report.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report, null, 2));

    await browser.close();
})().catch((e) => {
    console.error('FAILED:', e.message);
    process.exit(1);
});
