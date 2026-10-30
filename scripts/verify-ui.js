/**
 * On-device UI verification with a real browser.
 *
 * Verifies, in order:
 *   1. the native admin panel loads and we can log in
 *   2. the "GL-AI助手" entry is discoverable in the native sidebar menu
 *   3. the view bundle mounts (#/gl-ai renders our root element)
 *   4. the rendered text is correct (i18n resolved, not raw keys)
 *   5. the author credit is visible and links to the repository
 *   6. the interaction path animates and streams
 *
 *   GL_PASSWORD=… node scripts/verify-ui.js
 */
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const HOST = process.env.GL_HOST || '192.168.8.1';
const PASS = process.env.GL_PASSWORD;
if (!PASS) throw new Error('GL_PASSWORD is required for UI verification');
const OUT = path.resolve(__dirname, '../artifacts');

// The credit the page must carry, in both places it is rendered. Kept here as
// well as in the component so this check fails if either drifts.
const REPO_URL = 'https://github.com/XIAOZHAOXSXH/gl-ai-agent';
const AUTHOR_NAME = '小赵先生';

// A local router address must bypass the proxy or it will be black-holed.
const PROXY = process.env.GL_PROXY || 'http://127.0.0.1:7890';
const NO_PROXY = '127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12';

function findBrowser() {
    const candidates = [
        process.env.GL_BROWSER,
        'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
        'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
        process.env.LOCALAPPDATA + '\\Google\\Chrome\\Application\\chrome.exe',
        'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
        'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    ].filter(Boolean);
    for (const c of candidates) if (fs.existsSync(c)) return c;
    return undefined;
}

(async () => {
    fs.mkdirSync(OUT, { recursive: true });
    const base = `http://${HOST}`;
    const executablePath = findBrowser();
    console.log('browser:', executablePath || '(playwright bundled)');

    const browser = await chromium.launch({
        headless: true,
        executablePath,
        proxy: { server: PROXY, bypass: NO_PROXY },
        args: ['--no-sandbox', '--disable-dev-shm-usage'],
    });
    const ctx = await browser.newContext({
        ignoreHTTPSErrors: true,
        viewport: { width: 1500, height: 940 },
        deviceScaleFactor: 1,
    });
    const page = await ctx.newPage();

    const consoleErrors = [];
    const pageErrors = [];
    const failedRequests = [];
    const allRequests = [];
    page.on('console', (m) => {
        if (m.type() === 'error') consoleErrors.push(m.text());
    });
    page.on('pageerror', (e) => pageErrors.push(String(e)));
    page.on('requestfailed', (r) =>
        failedRequests.push(`${r.method()} ${r.url()} :: ${r.failure() && r.failure().errorText}`)
    );
    page.on('response', (r) => {
        const u = r.url();
        if (u.includes('gl-ai') || u.includes('gl_ai')) allRequests.push(`${r.status()} ${u}`);
    });

    // ---- 1. login ----------------------------------------------------
    console.log(`opening ${base}/#/login`);
    await page.goto(`${base}/#/login`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2500);
    const pwd = page.locator('input[type="password"]').first();
    if (await pwd.count()) {
        await pwd.fill(PASS);
        const btn = page.locator('.login-btn button, .login-btn .gl-button, button[type="submit"]').first();
        if (await btn.count()) await btn.click();
        else await pwd.press('Enter');
        await page.waitForTimeout(4500);
    }
    const loggedIn = page.url();
    console.log('after login:', loggedIn);

    // ---- 2. is our menu entry present in the native sidebar? ---------
    await page.goto(`${base}/#/overview`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(1800);
    const bodyText = await page.evaluate(() => document.body.innerText);
    const menuHit =
        bodyText.includes('GL-AI鍔╂墜') || bodyText.includes('GL-AI Assistant') || bodyText.includes('GL-AI');
    const rawMenuKey = bodyText.includes('menu_gl-ai') || bodyText.includes('menu_gl_ai');
    await page.screenshot({ path: path.join(OUT, '01-dashboard.png') });

    // ---- 3. navigate to the view -------------------------------------
    await page.goto(`${base}/#/gl-ai`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(4000);

    const rootCount = await page.locator('.gla').count();
    let heroTitle = '';
    let emptyTitle = '';
    let chips = [];
    if (rootCount) {
        heroTitle = await page.locator('.gla-hero-text h1').innerText().catch(() => '');
        emptyTitle = await page.locator('.gla-empty-title').innerText().catch(() => '');
        chips = await page.locator('.gla-suggest-item').allInnerTexts().catch(() => []);
    }
    await page.screenshot({ path: path.join(OUT, '02-view-empty.png') });
    fs.writeFileSync(
        path.join(OUT, '02-view-empty.html'),
        await page.content(),
        'utf8'
    );

    // ---- 3b. author credit -------------------------------------------
    // Both the hero byline and the footer line must be present, visible, and
    // point at the repository. This is a product requirement, not decoration:
    // the page is the only thing a user sees after installing the package, and
    // it has to say who wrote it.
    const author = await page.evaluate(() => {
        const hero = document.querySelector('.gla-author');
        const foot = document.querySelector('.gla-foot-author');
        const box = hero ? hero.getBoundingClientRect() : null;
        const norm = (el) => (el ? el.innerText.replace(/\s+/g, ' ').trim() : null);
        return {
            heroText: norm(hero),
            heroHref: hero ? hero.getAttribute('href') : null,
            heroTarget: hero ? hero.getAttribute('target') : null,
            heroRel: hero ? hero.getAttribute('rel') : null,
            heroVisible: !!box && box.width > 0 && box.height > 0,
            footText: norm(foot),
            footHref: foot ? foot.getAttribute('href') : null,
            overflowX: document.documentElement.scrollWidth > window.innerWidth + 1,
        };
    });
    const authorChecks = {
        heroBadgeVisible: author.heroVisible,
        heroSaysAuthor: !!author.heroText && author.heroText.includes(AUTHOR_NAME),
        heroLinksRepo: author.heroHref === REPO_URL,
        heroOpensNewTab: author.heroTarget === '_blank'
            && String(author.heroRel).includes('noopener'),
        footerSaysAuthor: !!author.footText && author.footText.includes(AUTHOR_NAME),
        footerLinksRepo: author.footHref === REPO_URL,
        noHorizontalOverflow: !author.overflowX,
    };
    await page.locator('.gla-hero').screenshot({ path: path.join(OUT, '02b-hero.png') }).catch(() => {});

    // ---- 4. exercise the interaction ---------------------------------
    if (chips.length) {
        await page.locator('.gla-suggest-item').first().click();
        await page.waitForTimeout(1400);
        await page.screenshot({ path: path.join(OUT, '03-thinking.png') });
        await page.waitForTimeout(5200);
        await page.screenshot({ path: path.join(OUT, '04-streamed.png') });
    }

    // ---- 5. dark theme pass ------------------------------------------
    // GL's themes come from localStorage, not from prefers-color-scheme: emulating
    // the media query leaves the page light, so this file used to be a copy of the
    // light one. Switch the real setting, check the tokens followed, then put the
    // user's theme back.
    const themeBefore = await page.evaluate(() => localStorage.getItem('theme'));
    await page.evaluate(() => localStorage.setItem('theme', 'dark'));
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3500);
    const darkTheme = await page.evaluate(() => {
        const a = document.querySelector('.gla-author');
        return {
            theme: localStorage.getItem('theme'),
            bodyBg: getComputedStyle(document.body).backgroundColor,
            badgeBg: a ? getComputedStyle(a).backgroundColor : null,
            badgeVisible: !!a && a.getBoundingClientRect().width > 0,
        };
    });
    await page.screenshot({ path: path.join(OUT, '05-dark.png') });
    await page.evaluate((t) => localStorage.setItem('theme', t || 'default'), themeBefore);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(1800);

    const snapshot = await page.evaluate(() => {
        const app = document.querySelector('#app');
        return app ? app.innerText.slice(0, 3000) : '(no #app)';
    });
    fs.writeFileSync(path.join(OUT, 'snapshot.txt'), snapshot, 'utf8');

    const report = {
        loggedInUrl: loggedIn,
        menuEntryVisible: menuHit,
        rawMenuKeyVisible: rawMenuKey,
        ourRootElements: rootCount,
        heroTitle,
        emptyTitle,
        suggestionChips: chips,
        author,
        authorChecks,
        darkTheme,
        glAiNetwork: allRequests,
        consoleErrors,
        pageErrors,
        failedRequests,
    };
    fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 2), 'utf8');

    console.log('\n===== REPORT =====');
    console.log(JSON.stringify(report, null, 2));

    await browser.close();

    // The credit is a product requirement: report it as a failure, not a note.
    const failedAuthorChecks = Object.entries(authorChecks)
        .filter(([, pass]) => !pass)
        .map(([name]) => name);
    if (failedAuthorChecks.length) {
        console.error('\nAUTHOR CREDIT CHECKS FAILED: ' + failedAuthorChecks.join(', '));
        process.exit(1);
    }
})().catch((e) => {
    console.error('VERIFY FAILED:', e.message);
    process.exit(1);
});
