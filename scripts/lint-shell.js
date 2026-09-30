/**
 * Syntax-check every shell file that ships in the package, plus the on-device
 * helper scripts.
 *
 * These run as /bin/sh (BusyBox ash) on the router, so a bashism is a real
 * defect: `set -o pipefail`, `[[ ]]` and arrays all fail there.
 *
 *   node scripts/lint-shell.js
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');

function walk(dir, out = []) {
    if (!fs.existsSync(dir)) return out;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, out);
        else if (e.name.endsWith('.sh')) out.push(p);
    }
    return out;
}

const files = [
    ...walk(path.join(ROOT, 'package')),
    ...walk(path.join(ROOT, 'deploy')),
    ...walk(path.join(ROOT, 'scripts')),
];

// control scripts have no .sh extension
for (const n of ['postinst', 'prerm', 'postrm', 'preinst']) {
    const p = path.join(ROOT, 'package/control', n);
    if (fs.existsSync(p)) files.push(p);
}

// Patterns that break under BusyBox ash.
//
// Each is anchored so that the same characters appearing inside a quoted string
// (a JSON payload, a Lua pattern, a grep expression) are not mistaken for shell
// syntax - a false positive here would train people to ignore the linter.
const BASHISMS = [
    [/(^|[;&|(]\s*)\[\[\s/, 'uses [[ ]] which BusyBox ash does not support'],
    [/^\s*set\s+-o\s+pipefail/m, 'uses `set -o pipefail`, unavailable in ash'],
    [/\$\{\w+\[@\]\}/, 'uses a bash array expansion'],
    [/^\s*function\s+\w+\s*\(\s*\)/m, 'uses the `function name()` form'],
    [/(^|\s)local\s+-[aA]\s/, 'uses `local -a`, a bash-only form'],
    [/\bdeclare\s+-[aA]\b/, 'uses `declare -a`, a bash-only builtin'],
];

let bad = 0;

// `sh -n` is the real check, but Windows has no sh. Detect it once and fall back
// to the pattern scan alone rather than failing every file for the wrong reason.
let haveSh = true;
try {
    execFileSync('sh', ['-c', 'true'], { stdio: 'ignore' });
} catch (e) {
    haveSh = false;
}
if (!haveSh) {
    console.log('no `sh` on this host; running the BusyBox pattern scan only\n');
}

for (const f of files.sort()) {
    const rel = path.relative(ROOT, f);
    let problems = [];

    if (haveSh) {
        try {
            execFileSync('sh', ['-n', f], { stdio: ['ignore', 'ignore', 'pipe'] });
        } catch (e) {
            problems.push('sh -n: ' + String(e.stderr || e.message).split('\n')[0]);
        }
    }

    const src = fs.readFileSync(f, 'utf8');
    for (const [re, why] of BASHISMS) {
        if (re.test(src)) problems.push(why);
    }

    if (problems.length) {
        bad++;
        console.log(`  FAIL  ${rel}`);
        problems.forEach((p) => console.log('          ' + p));
    } else {
        console.log(`  OK    ${rel}`);
    }
}

console.log(`\n${files.length} shell file(s), ${bad} problem(s)`);
process.exit(bad === 0 ? 0 : 1);
