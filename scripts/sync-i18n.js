/**
 * Add any missing keys to the UI locale files.
 *
 * The files are edited by hand as features land, so it is easy for one locale
 * to drift behind the others. Running this reports the diff and fills gaps -
 * with English text as the fallback, which is the least surprising thing a
 * partially translated UI can do.
 *
 *   node scripts/sync-i18n.js          # report only
 *   node scripts/sync-i18n.js --write  # fill gaps
 */
const fs = require('fs');
const path = require('path');

const DIR = path.resolve(__dirname, '../package/data/www/i18n');
const PREFIX = 'gl-sdk4-ui-gl-ai.';
const WRITE = process.argv.includes('--write');

function readJson(file) {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
}

const files = fs.readdirSync(DIR).filter((f) => f.startsWith(PREFIX) && f.endsWith('.json'));
if (!files.length) {
    console.error('no locale files found in ' + DIR);
    process.exit(1);
}

const locales = {};
for (const f of files) {
    locales[f] = readJson(path.join(DIR, f));
}

// English is the reference for structure; zh-cn is where new strings land first.
const reference = locales[PREFIX + 'en.json'] || locales[files[0]];
const union = new Set();
for (const f of files) {
    for (const k of Object.keys(locales[f].gl_ai || {})) union.add(k);
    if (locales[f].menu_gl_ai) union.add('menu_gl_ai');
}
for (const k of Object.keys(reference.gl_ai || {})) union.add(k);

// Build a fallback map from whichever locale already has a key.
const fallback = {};
for (const f of files) {
    for (const [k, v] of Object.entries(locales[f].gl_ai || {})) {
        if (!(k in fallback)) fallback[k] = v;
    }
}

let changed = 0;
for (const f of files) {
    const data = locales[f];
    const missing = [];
    for (const k of [...union].sort()) {
        if (k === 'menu_gl_ai') {
            if (!data.menu_gl_ai) missing.push(k);
            continue;
        }
        if (!(k in (data.gl_ai || {}))) missing.push(k);
    }
    if (!missing.length) {
        console.log(`  OK    ${f}`);
        continue;
    }
    console.log(`  ${WRITE ? 'PATCH' : 'MISS'} ${f}  -> ${missing.join(', ')}`);
    if (WRITE) {
        for (const k of missing) {
            if (k === 'menu_gl_ai') data.menu_gl_ai = fallback.menu_gl_ai || 'GL-AI Assistant';
            else data.gl_ai[k] = fallback[k] || k;
        }
        fs.writeFileSync(path.join(DIR, f), JSON.stringify(data, null, 4) + '\n', 'utf8');
        changed++;
    }
}

console.log(`\n${files.length} locales, ${union.size} keys${WRITE ? `, ${changed} patched` : ''}`);
