/**
 * Archive helper built on the platform `tar`, with a fallback writer.
 *
 * Why two paths
 * -------------
 * The archive must carry explicit file modes: the SDK loads an RPC object only
 * if it is executable, and the tar bundled with Windows (bsdtar) records the
 * filesystem's permissions while offering neither `--mode` nor `--owner`. On
 * Windows `fs.chmodSync` is a no-op too - a file stays 0666 - so a package built
 * there would ship a non-executable RPC object and fail on the router.
 *
 * GNU tar (the Linux CI runners) handles this perfectly: --owner/--group/
 * --numeric-owner/--mtime plus the real on-disk modes. So:
 *
 *   GNU tar available -> use it, fully reproducible
 *   otherwise         -> write the ustar archive directly, applying the modes we
 *                        are given, which is exactly what bsdtar cannot do
 *
 * ustar (POSIX) is used rather than GNU format because both tar flavours read it
 * and it avoids the ././@LongLink extension; paths that exceed its 100-byte name
 * field fall back to the 155-byte prefix field, which this writer supports.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { execFileSync } = require('child_process');

const BLOCK = 512;

// ---------------------------------------------------------------------------
// capability probe
// ---------------------------------------------------------------------------

let flavour = null;

/** 'gnu' when this tar accepts the reproducibility flags, else 'manual'. */
function detect() {
    if (flavour) return flavour;
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tartz-'));
    try {
        fs.writeFileSync(path.join(dir, 'f'), 'x');
        execFileSync('tar', [
            '--format=ustar', '-cf', path.join(dir, 'p.tar'),
            '--owner=0', '--group=0', '--numeric-owner', '--mtime=@0',
            '-C', dir, 'f',
        ], { stdio: 'ignore' });
        flavour = 'gnu';
    } catch (e) {
        flavour = 'manual';
    }
    try {
        fs.rmSync(dir, { recursive: true, force: true });
    } catch (e) { /* best effort */ }
    return flavour;
}

// ---------------------------------------------------------------------------
// manual ustar writer (used where tar cannot set modes)
// ---------------------------------------------------------------------------

function octal(value, len) {
    // numeric fields are zero-padded octal with a trailing NUL
    return value.toString(8).padStart(len - 1, '0') + '\0';
}

function header({ name, mode, size, type, mtime = 0 }) {
    const buf = Buffer.alloc(BLOCK, 0);
    let nm = name;
    let prefix = '';

    if (Buffer.byteLength(nm) > 100) {
        const idx = nm.lastIndexOf('/', nm.length - 100);
        if (idx > 0) {
            prefix = nm.slice(0, idx);
            nm = nm.slice(idx + 1);
        }
        if (Buffer.byteLength(prefix) > 155) {
            // no ustar representation; the manual path is only used on Windows
            // for our own trees, which are shallow enough that this is a bug
            throw new Error(`path too long for ustar: ${name}`);
        }
    }

    buf.write(nm + '\0', 0, Math.min(100, Buffer.byteLength(nm) + 1), 'utf8');
    buf.write(octal(mode & 0o7777, 8), 100, 8, 'ascii');
    buf.write(octal(0, 8), 108, 8, 'ascii');            // uid
    buf.write(octal(0, 8), 116, 8, 'ascii');            // gid
    buf.write(octal(size, 12), 124, 12, 'ascii');
    buf.write(octal(mtime, 12), 136, 12, 'ascii');
    buf.write('        ', 148, 8, 'ascii');             // checksum placeholder
    buf.write(type, 156, 1, 'ascii');
    buf.write('ustar\0', 257, 6, 'ascii');              // magic
    buf.write('00', 263, 2, 'ascii');                   // version
    buf.write('root\0', 265, 32, 'ascii');
    buf.write('root\0', 297, 32, 'ascii');
    if (prefix) buf.write(prefix + '\0', 345, Math.min(155, Buffer.byteLength(prefix) + 1), 'utf8');

    let sum = 0;
    for (let i = 0; i < BLOCK; i++) sum += buf[i];
    buf.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
    return buf;
}

function collect(rootDir) {
    const entries = [];
    const walk = (dir, rel) => {
        const items = fs.readdirSync(dir, { withFileTypes: true })
            .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
        for (const it of items) {
            const abs = path.join(dir, it.name);
            const r = rel ? `${rel}/${it.name}` : it.name;
            if (it.isDirectory()) {
                entries.push({ rel: r, abs, dir: true });
                walk(abs, r);
            } else if (it.isFile()) {
                entries.push({ rel: r, abs, dir: false });
            }
        }
    };
    walk(rootDir, '');
    return entries;
}

function manualTarGz(rootDir, outFile, modeFor) {
    const chunks = [header({ name: './', mode: 0o755, size: 0, type: '5' })];

    for (const e of collect(rootDir)) {
        const name = './' + e.rel + (e.dir ? '/' : '');
        if (e.dir) {
            chunks.push(header({ name, mode: 0o755, size: 0, type: '5' }));
        } else {
            const data = fs.readFileSync(e.abs);
            chunks.push(header({
                name,
                mode: modeFor ? modeFor(e.rel, false) : 0o644,
                size: data.length,
                type: '0',
            }));
            chunks.push(data);
            const rem = data.length % BLOCK;
            if (rem) chunks.push(Buffer.alloc(BLOCK - rem, 0));
        }
    }

    chunks.push(Buffer.alloc(BLOCK, 0), Buffer.alloc(BLOCK, 0));
    const gz = zlib.gzipSync(Buffer.concat(chunks), { level: 9 });
    fs.writeFileSync(outFile, gz);
    return gz;
}

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

/**
 * Create a gzipped tar of `rootDir`'s contents.
 *
 * @param {string} rootDir
 * @param {string} outFile
 * @param {(rel:string, isDir:boolean)=>number} [modeFor]
 *        Modes to record. Honoured by the manual writer; under GNU tar the
 *        modes already on disk are used instead, so callers should still chmod
 *        (applyModes does) for the CI path.
 * @returns {Buffer}
 */
function tarGz(rootDir, outFile, modeFor) {
    if (detect() === 'gnu') {
        execFileSync('tar', [
            '--format=ustar', '-czf', outFile,
            '--owner=0', '--group=0', '--numeric-owner', '--mtime=@0',
            '-C', rootDir, '.',
        ], { stdio: ['ignore', 'ignore', 'pipe'] });
        return fs.readFileSync(outFile);
    }
    return manualTarGz(rootDir, outFile, modeFor);
}

function rmrf(p) {
    fs.rmSync(p, { recursive: true, force: true });
}

function copyDir(src, dst) {
    fs.mkdirSync(dst, { recursive: true });
    for (const e of fs.readdirSync(src, { withFileTypes: true })) {
        const s = path.join(src, e.name);
        const d = path.join(dst, e.name);
        if (e.isDirectory()) copyDir(s, d);
        else fs.copyFileSync(s, d);
    }
}

/** Set modes where the filesystem allows it; the CI (GNU tar) path needs this. */
function applyModes(rootDir, isExec) {
    const walk = (dir, rel) => {
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            const abs = path.join(dir, e.name);
            const r = rel ? `${rel}/${e.name}` : e.name;
            try {
                fs.chmodSync(abs, e.isDirectory() ? 0o755 : (isExec(r) ? 0o755 : 0o644));
            } catch (err) { /* Windows ignores this; the manual writer covers it */ }
            if (e.isDirectory()) walk(abs, r);
        }
    };
    walk(rootDir, '');
}

module.exports = { tarGz, rmrf, copyDir, applyModes, flavour: () => detect() };
