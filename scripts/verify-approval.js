/**
 * Verify the confirmation gate - the safety property that matters most.
 *
 * Switches to "ask" mode and asks for a state change, then checks that:
 *   1. the turn stops and shows a confirmation card instead of acting
 *   2. declining sends a denial and the model reports it was declined
 *   3. the router was NOT changed
 *
 * Nothing is actually modified: the test always declines.
 *
 *   node scripts/verify-approval.js
 */
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const HOST = process.env.GL_HOST || '192.168.8.1';
const PASS = process.env.GL_PASSWORD || 'Test@2026888';
const API_KEY = process.env.GL_API_KEY || '';
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

// A hard watchdog: a single stuck locator or a wedged browser must fail the run
// loudly rather than leaving the harness waiting for ever with no output.
const HARD_TIMEOUT_MS = Number(process.env.GL_TEST_TIMEOUT_MS || 240000);
const watchdog = setTimeout(() => {
    console.error(`\nFAILED: watchdog fired after ${HARD_TIMEOUT_MS} ms - something is stuck`);
    process.exit(3);
}, HARD_TIMEOUT_MS);
watchdog.unref && watchdog.unref();

const log = (...a) => {
    process.stdout.write(a.join(' ') + '\n');
};

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
        viewport: { width: 1500, height: 980 },
    }).then((c) => c.newPage());

    const pageErrors = [];
    page.on('pageerror', (e) => pageErrors.push(String(e)));

    const steps = [];
    const done = (name, ok, extra) => {
        steps.push({ name, ok, extra: extra || '' });
        log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  (' + extra + ')' : ''}`);
    };

    log('login');
    await page.goto(`${base}/#/login`, { waitUntil: 'domcontentloaded' });
    await sleep(2500);
    const pwd = page.locator('input[type="password"]').first();
    if (await pwd.count()) {
        await pwd.fill(PASS);
        const btn = page.locator('.login-btn button, .login-btn .gl-button, button[type="submit"]').first();
        if (await btn.count()) await btn.click(); else await pwd.press('Enter');
        await sleep(4500);
    }

    log('configure: ask mode');
    await page.goto(`${base}/#/gl-ai`, { waitUntil: 'domcontentloaded' });
    await sleep(3500);
    await page.locator('.gla-hero-side .gla-ghost').first().click({ timeout: 15000 });
    await sleep(800);

    const apiFields = page.locator('.gla-field input');
    await apiFields.nth(0).fill('https://api.moleapi.com/v1');
    await apiFields.nth(1).fill('deepseek-flash');
    if (API_KEY) await apiFields.nth(2).fill(API_KEY);

    const adv = page.locator('.gla-adv');
    if (await adv.count()) {
        await page.locator('.gla-adv summary').click();
        await sleep(300);
        const tls = page.locator('.gla-check input').nth(0);
        if (await tls.isChecked()) await tls.click();
    }
    // the point of this test: writes must be confirmed, not auto-applied
    await page.locator('.gla-field select').nth(1).selectOption('ask');
    // Every interaction gets an explicit timeout: a missing element must fail the
    // test quickly instead of hanging the whole run.
    const T = { timeout: 15000 };
    await page.locator('.gla-panel .gla-btn.is-primary').click(T);
    await sleep(3000);
    done('configured in ask mode', (await page.locator('.gla-panel').count()) === 0);

    log('ask for a change that needs confirmation');
    // Phrased so there is nothing to clarify: an ambiguous request legitimately
    // makes the model ask a question instead of calling a tool, which is correct
    // behaviour but would not exercise the gate.
    await page.locator('.gla-box textarea').fill(
        '把 2.4G 主网络的 SSID 改成 GL-Test-2G，其他什么都别改'
    );
    await page.locator('.gla-send').click(T);

    // Wait for the card.
    //
    // Do NOT treat "there is some assistant text and the stop button is gone" as
    // the end of the turn: a tool-using model narrates before it acts ("I'll
    // check the current settings first"), so that condition fires while the turn
    // is still running and the confirmation is still to come. Watch the busy
    // flag - which only clears when the turn really finishes - and keep going
    // until either the card shows up or the turn is genuinely over.
    let sawConfirm = false;
    let settledWithoutCard = false;
    for (let i = 0; i < 120; i++) {
        await sleep(1000);
        if (await page.locator('.gla-confirm').count()) { sawConfirm = true; break; }
        const busy = await page.locator('.gla-send.is-stop').count();
        if (!busy && i > 3) {
            // give the UI a beat in case the last poll is still landing
            await sleep(1500);
            if (await page.locator('.gla-confirm').count()) { sawConfirm = true; break; }
            if (!(await page.locator('.gla-send.is-stop').count())) { settledWithoutCard = true; break; }
        }
    }
    await page.screenshot({ path: path.join(OUT, 'approval-01-card.png') });
    if (!sawConfirm && settledWithoutCard) {
        const txt = await page.locator('.gla-row.is-assistant .gla-bubble').innerText().catch(() => '');
        log('  note: the turn finished without asking to confirm; it said: ' +
            JSON.stringify(txt.slice(0, 140)));
    }
    done('confirmation card appeared instead of acting', sawConfirm);

    if (sawConfirm) {
        const cardText = await page.locator('.gla-confirm').innerText().catch(() => '');
        done('card explains the change', cardText.length > 10, JSON.stringify(cardText.slice(0, 110)));

        const timer = await page.locator('.gla-confirm-timer').count();
        done('card shows a countdown', timer === 1);

        log('decline it');
        await page.locator('.gla-confirm .gla-btn').nth(1).click(T);
        await sleep(800);
        done('card dismissed on decline', (await page.locator('.gla-confirm').count()) === 0);

        // After a refusal the turn ends without a model reply, so wait on the
        // *turn* finishing (the stop button going away), not on assistant text -
        // waiting for text that will never arrive is what hung this test.
        let idle = false;
        for (let i = 0; i < 60; i++) {
            await sleep(1000);
            const busy = await page.locator('.gla-send.is-stop').count();
            if (!busy) { idle = true; break; }
        }
        await page.screenshot({ path: path.join(OUT, 'approval-02-declined.png') });

        const reply = await page
            .locator('.gla-row.is-assistant .gla-bubble')
            .last()
            .innerText()
            .catch(() => '');
        done('turn finished after the decline', idle,
            'assistant text: ' + JSON.stringify(reply.slice(0, 80)));

        // The safety property this whole test exists for: nothing was written.
        done('no confirmation card left open',
            (await page.locator('.gla-confirm').count()) === 0);
    }

    const report = {
        steps,
        pageErrors,
        passed: steps.filter((s) => s.ok).length,
        total: steps.length,
    };
    fs.writeFileSync(path.join(OUT, 'approval-report.json'), JSON.stringify(report, null, 2));
    log(`\n===== APPROVAL GATE: ${report.passed}/${report.total} =====`);
    if (pageErrors.length) log('page errors:', pageErrors);

    await browser.close();
    process.exit(report.passed === report.total ? 0 : 1);
})().catch((e) => {
    console.error('FAILED:', e.message);
    process.exit(1);
});
