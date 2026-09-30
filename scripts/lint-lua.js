/**
 * Syntax-check every Lua file that ships in the package.
 *
 * The router runs Lua 5.1, so the check must be 5.1 too: a file that parses
 * under 5.4 can still fail on the device. Tries `luac5.1`, `luac`, then
 * `lua5.1 -e "assert(loadfile(...))"`, and skips cleanly if none is present so
 * that a workstation without Lua is not blocked.
 *
 *   node scripts/lint-lua.js
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'package/data');

/** Files that are Lua source but have no .lua extension. */
const EXTRA = [
    'usr/lib/oui-httpd/rpc/gl_ai',
];

function walk(dir, out = []) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, out);
        else if (e.name.endsWith('.lua')) out.push(p);
    }
    return out;
}

function have(cmd, args) {
    try {
        execFileSync(cmd, args, { stdio: 'ignore' });
        return true;
    } catch (e) {
        return e.status === 0 || e.status === undefined ? false : false;
    }
}

// pick a Lua 5.1-compatible checker
let check = null;
if (have('luac5.1', ['-v'])) check = (f) => execFileSync('luac5.1', ['-p', f]);
else if (have('luac', ['-v'])) check = (f) => execFileSync('luac', ['-p', f]);
else if (have('lua5.1', ['-v'])) {
    check = (f) =>
        execFileSync('lua5.1', ['-e', `assert(loadfile('${f}'))`], { stdio: 'ignore' });
} else {
    console.log('no Lua 5.1 toolchain found; skipping the syntax check');
    process.exit(0);
}

const files = [...walk(path.join(DATA, 'usr/lib/lua')), ...walk(path.join(DATA, 'usr/share/gl-validator.d'))];
for (const rel of EXTRA) {
    const p = path.join(DATA, rel);
    if (fs.existsSync(p)) files.push(p);
}

let bad = 0;
for (const f of files.sort()) {
    try {
        check(f);
        console.log(`  OK    ${path.relative(ROOT, f)}`);
    } catch (e) {
        bad++;
        console.log(`  FAIL  ${path.relative(ROOT, f)}`);
        console.log(String(e.stderr || e.message).split('\n').slice(0, 4).join('\n'));
    }
}

// The SDK binds these by name, so a typo here is a silent no-op on device.
const rpc = path.join(DATA, 'usr/lib/oui-httpd/rpc/gl_ai');
if (fs.existsSync(rpc)) {
    const src = fs.readFileSync(rpc, 'utf8');
    // a bare `return require ...` would re-introduce the module cache problem
    if (!src.includes('loadfile')) {
        bad++;
        console.log('  FAIL  rpc entry does not loadfile() its backend; the nginx');
        console.log('        module cache would then require a restart per upgrade');
    }
}

console.log(`\n${files.length} Lua file(s), ${bad} problem(s)`);
process.exit(bad === 0 ? 0 : 1);
