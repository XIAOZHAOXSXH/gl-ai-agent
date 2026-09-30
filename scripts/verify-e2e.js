/**
 * End-to-end interaction check on the real device.
 *
 * Walks the whole product path a user would take:
 *   login -> open GL-AI鍔╂墜 -> open settings -> fill the form -> save
 *         -> send a message -> poll the turn -> render the result
 *
 * With a base_url that resolves but no valid key, the turn is expected to end
 * with a rendered error. That still proves the timer, the event log, the poll
 * loop and the renderer all work - which is exactly what this verifies.
 *
 *   node scripts/verify-e2e.js
 */
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const HOST = process.env.GL_HOST || '192.168.8.1';
const PASS = process.env.GL_PASSWORD || 'Test@2026888';
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

    const consoleErrors = [];
    const pageErrors = [];
    const rpcCalls = [];
    page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
    page.on('pageerror', (e) => pageErrors.push(String(e)));
    page.on('response', (r) => {
        if (r.url().endsWith('/rpc')) rpcCalls.push(r.status());
    });

    const steps = [];
    const done = (name, ok, extra) => {
        steps.push({ name, ok, extra: extra || '' });
        console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  (' + extra + ')' : ''}`);
    };

    // ---- login -------------------------------------------------------
    console.log('step 1: login');
    await page.goto(`${base}/#/login`, { waitUntil: 'domcontentloaded' });
    await sleep(2500);
    const pwd = page.locator('input[type="password"]').first();
    if (await pwd.count()) {
        await pwd.fill(PASS);
        const btn = page.locator('.login-btn button, .login-btn .gl-button, button[type="submit"]').first();
        if (await btn.count()) await btn.click(); else await pwd.press('Enter');
        await sleep(4500);
    }
    done('logged in', page.url().includes('#/internet') || !page.url().includes('login'), page.url());

    // ---- open the page ----------------------------------------------
    console.log('step 2: open GL-AI鍔╂墜');
    await page.goto(`${base}/#/gl-ai`, { waitUntil: 'domcontentloaded' });
    await sleep(3500);
    const root = await page.locator('.gla').count();
    done('view mounted', root === 1);

    // ---- open settings ----------------------------------------------
    console.log('step 3: settings panel');
    const gear = page.locator('.gla-hero-side .gla-ghost').first();
    await gear.click();
    await sleep(700);
    const panel = await page.locator('.gla-panel').count();
    done('settings panel opens', panel === 1);
    await page.screenshot({ path: path.join(OUT, 'e2e-01-settings.png') });

    // .gla-field inputs are the three API fields; the two advanced options are
    // checkboxes under .gla-check, so scope the count accordingly.
    const fields = await page.locator('.gla-field input').count();
    const selects = await page.locator('.gla-field select').count();
    done('form controls present', fields === 3 && selects === 2, `${fields} inputs, ${selects} selects`);

    // ---- fill and save ----------------------------------------------
    console.log('step 4: save configuration');
    const apiFields = page.locator('.gla-field input');
    await apiFields.nth(0).fill(process.env.GL_BASE_URL || 'https://api.moleapi.com/v1');
    await apiFields.nth(1).fill(process.env.GL_MODEL || 'deepseek-flash');
    const apiKey = process.env.GL_API_KEY || '';
    if (apiKey) {
        await apiFields.nth(2).fill(apiKey);
    }

    // This network's upstream presents a self-signed certificate, so TLS
    // verification has to come off for the router to reach the provider.
    const adv = page.locator('.gla-adv');
    if (await adv.count()) {
        await page.locator('.gla-adv summary').click();
        await sleep(400);
        const tls = page.locator('.gla-check input').nth(0);
        if (await tls.count()) {
            const checked = await tls.isChecked();
            if (checked) await tls.click();
            done('TLS verification can be turned off', !(await tls.isChecked()));
        }
    }
    // read-only keeps the test from changing the router
    await page.locator('.gla-panel select').nth(1).selectOption('readonly');

    await page.locator('.gla-panel .gla-btn.is-primary').click();
    await sleep(3000);
    const panelGone = await page.locator('.gla-panel').count();
    done('save closes the panel', panelGone === 0);

    const status = await page.locator('.gla-chip').innerText().catch(() => '');
    const foot = await page.locator('.gla-foot-pill').innerText().catch(() => '');
    // '\u672a\u914d\u7f6e' is what the chip shows before a provider is saved
    done('UI reflects configuration', !status.includes('\u672a\u914d\u7f6e'),
        'status=' + status.trim() + ' foot=' + foot.trim());

    // ---- send a message ---------------------------------------------
    console.log('step 5: send a message and let the agent work');
    await page.locator('.gla-suggest-item').first().click();
    await sleep(600);
    const userBubble = await page.locator('.gla-row.is-user .gla-bubble').count();
    done('user message rendered', userBubble === 1);

    // The turn runs step by step, each step a model call; a reasoning model
    // needs a generous window.
    let text = '';
    for (let i = 0; i < 150; i++) {
        await sleep(1000);
        text = await page.locator('.gla-row.is-assistant .gla-bubble').innerText().catch(() => '');
        const busy = await page.locator('.gla-send.is-stop').count();
        if (text.trim().length > 0 && !busy) break;
    }
    done('turn produced a rendered reply', text.trim().length > 0, JSON.stringify(text.slice(0, 110)));

    const toolSteps = await page.locator('.gla-step').allInnerTexts().catch(() => []);
    done('tool timeline rendered', toolSteps.length >= 1, `${toolSteps.length} step(s)`);

    const failed = /\u51fa\u9519\u4e86|\u5931\u8d25|\u9519\u8bef/.test(text);
    if (apiKey) {
        done('live model answered without error', !failed, JSON.stringify(text.slice(0, 80)));
    } else {
        done('no API key supplied, so a plain-language error is expected', failed);
    }

    await page.screenshot({ path: path.join(OUT, 'e2e-02-conversation.png') });

    const busyAfter = await page.locator('.gla-send.is-stop').count();
    done('idle again after the turn', busyAfter === 0);

    const report = {
        steps,
        consoleErrors,
        pageErrors,
        rpcResponses: rpcCalls,
        passed: steps.filter((s) => s.ok).length,
        total: steps.length,
    };
    fs.writeFileSync(path.join(OUT, 'e2e-report.json'), JSON.stringify(report, null, 2));
    console.log('\n===== E2E RESULT =====');
    console.log(`${report.passed}/${report.total} checks passed`);
    if (consoleErrors.length) console.log('console errors:', consoleErrors);
    if (pageErrors.length) console.log('page errors:', pageErrors);

    await browser.close();
    process.exit(report.passed === report.total ? 0 : 1);
})().catch((e) => {
    console.error('E2E FAILED:', e.message);
    process.exit(1);
});
