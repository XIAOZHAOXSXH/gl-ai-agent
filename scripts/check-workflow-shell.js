/**
 * Syntax-check the shell that lives inside the GitHub workflow.
 *
 * `scripts/lint-shell.js` covers every shell file in the repository, but the
 * largest shell scripts here are the `run:` blocks in .github/workflows, and
 * they were the only ones nothing checked. A stray quote in one of them costs a
 * full CI round trip to discover, and on a slow runner that is minutes per typo.
 *
 * There is no YAML parser in this project's dependencies, so the blocks are
 * extracted by indentation: `run:` followed by a `|` starts a literal block that
 * continues while lines are indented deeper than the key. That is exactly how
 * the workflow uses it, and anything it cannot make sense of is reported rather
 * than skipped.
 *
 *   node scripts/check-workflow-shell.js
 *   node scripts/check-workflow-shell.js --keep /tmp/wfsh   # leave blocks for
 *                                                          # checking elsewhere
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const WF_DIR = path.join(ROOT, '.github/workflows');

/**
 * Pull every `run:` block out of a workflow.
 *
 * @returns {{name: string, line: number, script: string}[]}
 */
function extractRuns(text) {
    const lines = text.split(/\r?\n/);
    const blocks = [];
    let stepName = '(unnamed step)';

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        const named = line.match(/^\s*-?\s*name:\s*(.+?)\s*$/);
        if (named) stepName = named[1].replace(/^["']|["']$/g, '');

        const run = line.match(/^(\s*)(?:-\s*)?run:\s*(.*)$/);
        if (!run) continue;

        const indent = run[1].length;
        const inline = run[2];

        // `run: echo hi` - a single command on the key's own line.
        if (inline && !/^[|>]/.test(inline)) {
            blocks.push({ name: stepName, line: i + 1, script: inline });
            continue;
        }
        if (!inline) {
            // `run:` with the command on the next line(s), indented.
            const body = [];
            let j = i + 1;
            for (; j < lines.length; j++) {
                const l = lines[j];
                if (l.trim() === '') {
                    body.push('');
                    continue;
                }
                if (l.match(/^\s*/)[0].length <= indent) break;
                body.push(l);
            }
            if (body.some((l) => l.trim())) {
                blocks.push({
                    name: stepName,
                    line: i + 1,
                    script: dedent(body).join('\n') + '\n',
                });
            }
            i = j - 1;
            continue;
        }

        // `run: |` - a literal block whose indentation sets the body's.
        const body = [];
        let j = i + 1;
        let bodyIndent = null;
        for (; j < lines.length; j++) {
            const l = lines[j];
            if (l.trim() === '') {
                body.push('');
                continue;
            }
            const li = l.match(/^\s*/)[0].length;
            if (li <= indent) break;
            if (bodyIndent === null) bodyIndent = li;
            body.push(l);
        }
        blocks.push({
            name: stepName,
            line: i + 1,
            script: dedent(body).join('\n') + '\n',
        });
        i = j - 1;
    }
    return blocks;
}

function dedent(lines) {
    const indents = lines.filter((l) => l.trim()).map((l) => l.match(/^\s*/)[0].length);
    const min = indents.length ? Math.min(...indents) : 0;
    return lines.map((l) => l.slice(min));
}

/**
 * Patterns that are definitely wrong in a runner or Alpine job shell.
 *
 * Each is unambiguous, because a linter that cries wolf is a linter people
 * learn to ignore.
 */
const SHELL_TRAPS = [
    [/^\s*set\s+-o\s+pipefail/m, 'uses `set -o pipefail`, which the Alpine container shell lacks'],
    [/^\s*\[\[/, 'uses [[ ]], unavailable in ash/dash'],
];

/**
 * Shapes worth a second look, but not proof of a bug.
 *
 * A pipeline into `tee` reports tee's status, so a failure can pass unnoticed -
 * unless the status was captured first, which is the fix and appears in the same
 * block. A diagnostic step that only needs to print is fine either way.
 */
function looksRisky(script) {
    const notes = [];
    if (/\|\s*tee\b/.test(script) && !/status=\$\?/.test(script)) {
        notes.push('pipes into tee without capturing the status first: a failure there can pass');
    }
    return notes;
}

const keepIdx = process.argv.indexOf('--keep');
const keep = keepIdx >= 0 ? process.argv[keepIdx + 1] : null;
const tmp = keep ? path.resolve(keep) : fs.mkdtempSync(path.join(os.tmpdir(), 'wfsh-'));
fs.mkdirSync(tmp, { recursive: true });

let haveSh = true;
try {
    execFileSync('sh', ['-c', 'true'], { stdio: 'ignore' });
} catch (e) {
    haveSh = false;
}
if (!haveSh) {
    console.log('no `sh` on this host; running the pattern scan only\n');
}

let total = 0;
let bad = 0;

for (const file of fs.readdirSync(WF_DIR).filter((f) => /\.ya?ml$/.test(f)).sort()) {
    const text = fs.readFileSync(path.join(WF_DIR, file), 'utf8');
    const blocks = extractRuns(text);
    console.log(`${file}: ${blocks.length} run block(s)`);

    blocks.forEach((b, n) => {
        total++;
        const rel = `${file}#${n + 1}`;
        const out = path.join(tmp, `${file}-${String(n + 1).padStart(2, '0')}.sh`);
        fs.writeFileSync(out, b.script);

        const problems = [];
        if (haveSh) {
            try {
                execFileSync('sh', ['-n', out], { stdio: ['ignore', 'ignore', 'pipe'] });
            } catch (e) {
                problems.push('sh -n: ' + String(e.stderr || e.message).split('\n')[0]);
            }
        }
        for (const [re, why] of SHELL_TRAPS) {
            if (re.test(b.script)) problems.push(why);
        }
        const notes = looksRisky(b.script);

        if (problems.length) {
            bad++;
            console.log(`  FAIL  line ${b.line}  ${b.name}`);
            problems.forEach((p) => console.log('          ' + p));
        } else if (notes.length) {
            console.log(`  OK    line ${b.line}  ${b.name}`);
            notes.forEach((n) => console.log('          note: ' + n));
        } else {
            console.log(`  OK    line ${b.line}  ${b.name}`);
        }
    });
}

if (keep) console.log(`\nblocks kept in ${tmp}`);
else fs.rmSync(tmp, { recursive: true, force: true });

console.log(`\n${total} run block(s), ${bad} problem(s)`);
process.exit(bad === 0 ? 0 : 1);
