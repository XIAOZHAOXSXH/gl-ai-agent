/**
 * The package checker is what proves a built package is installable, so it has
 * to be right about every container format it claims to read. The APKv3 reader
 * in particular cannot be exercised against a real `apk mkpkg` output on a
 * Windows workstation (no Alpine, no container runtime), and a checker that
 * silently mis-reads a format is worse than no checker.
 *
 * So it is tested against synthetic fixtures assembled here:
 *   - APKv2: one gzipped tar holding .PKGINFO + data/ + dot-prefixed scripts
 *   - APKv3: three concatenated streams (signature, control, data), which is the
 *     shape apk-tools 3 emits and the shape that broke CI
 *   - OpenWrt 22.03 ipk: a gzipped tar wrapping debian-binary + control/data tars
 *   - the legacy ar ipk
 *
 *   node scripts/check-package-formats.js
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const CHECKER = path.join(ROOT, 'scripts/check-package.js');

const BLOCK = 512;

// ---------------------------------------------------------------------------
// a minimal ustar writer, so the fixtures do not depend on the local tar
// ---------------------------------------------------------------------------

function octal(value, len) {
    return value.toString(8).padStart(len - 1, '0') + '\0';
}

function header({ name, mode = 0o644, size = 0, type = '0' }) {
    const buf = Buffer.alloc(BLOCK, 0);
    buf.write(name + '\0', 0, Math.min(100, Buffer.byteLength(name) + 1), 'utf8');
    buf.write(octal(mode, 8), 100, 8, 'ascii');
    buf.write(octal(0, 8), 108, 8, 'ascii');
    buf.write(octal(0, 8), 116, 8, 'ascii');
    buf.write(octal(size, 12), 124, 12, 'ascii');
    buf.write(octal(0, 12), 136, 12, 'ascii');
    buf.write('        ', 148, 8, 'ascii');
    buf.write(type, 156, 1, 'ascii');
    buf.write('ustar\0', 257, 6, 'ascii');
    buf.write('00', 263, 2, 'ascii');
    let sum = 0;
    for (let i = 0; i < BLOCK; i++) sum += buf[i];
    buf.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
    return buf;
}

function tar(files) {
    const chunks = [];
    for (const [name, content, mode] of files) {
        const data = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
        chunks.push(header({ name, size: data.length, mode: mode || 0o644 }));
        chunks.push(data);
        const rem = data.length % BLOCK;
        if (rem) chunks.push(Buffer.alloc(BLOCK - rem, 0));
    }
    chunks.push(Buffer.alloc(BLOCK, 0), Buffer.alloc(BLOCK, 0));
    return Buffer.concat(chunks);
}

/** The payload the checker is supposed to find in every fixture. */
const PAYLOAD = [
    ['usr/lib/lua/glai/agent.lua', '-- agent\n'],
    ['usr/lib/lua/glai/tools.lua', '-- tools\n'],
    ['usr/lib/lua/glai/llm.lua', '-- llm\n'],
    ['usr/lib/lua/glai/rpc_entry.lua', '-- entry\n'],
    ['usr/lib/oui-httpd/rpc/gl_ai', 'return {}\n', 0o755],
    ['usr/share/oui/menu.d/gl-ai.json', '{}\n'],
    ['usr/share/gl-validator.d/gl_ai.lua', 'return {}\n'],
    ['www/js/gl-ai-agent-boot.js', '\n'],
    ['www/views/gl-sdk4-ui-gl-ai.common.js', '\n'],
    ['www/views/gl-sdk4-ui-gl-ai.common.js.gz', Buffer.from([0x1f, 0x8b, 0, 0])],
    ['www/i18n/gl-sdk4-ui-gl-ai.zh-cn.json', '{}\n'],
    ['www/i18n/gl-sdk4-ui-gl-ai.en.json', '{}\n'],
];

const CONTROL = 'Package: gl-ai-agent\nVersion: 0.1.0\nArchitecture: all\n'
    + 'Description: test fixture\n';

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

/** APKv2: one gzipped tar. */
function makeApkv2() {
    const body = tar([
        ['.PKGINFO', 'pkgname = gl-ai-agent\npkgver = 0.1.0-r1\narch = noarch\n'],
        ...PAYLOAD.map(([n, c, m]) => ['data/' + n, c, m]),
        ['.post-install', '#!/bin/sh\nexit 0\n', 0o755],
    ]);
    return zlib.gzipSync(body);
}

/**
 * APKv3: signature stream, ADB control stream, tar data stream.
 *
 * Mirrors what apk-tools 3 actually emits. Two details are easy to get wrong and
 * both are load-bearing for the checker:
 *   - the control stream is ADB, NOT tar, so it cannot be read with a tar reader
 *   - the data stream holds the tree directly (usr/..., www/...), without a
 *     "data/" prefix
 */
function makeApkv3() {
    // The signature stream has no gzip magic; a short opaque record stands in
    // for the real APK signature so that offset 0 is genuinely non-gzip.
    const sig = Buffer.concat([
        Buffer.from('debian-binary\n', 'ascii'),
        Buffer.from([0x89, 0x41, 0x50, 0x4b, 0x53, 0x49, 0x47, 0x00]),
        Buffer.alloc(64, 0xab),
    ]);

    // ADB stands in for apk's control stream: gzip'd, but not a tar.
    const adbControl = zlib.gzipSync(Buffer.concat([
        Buffer.from('2.0\n', 'ascii'),
        Buffer.from('pkgname=gl-ai-agent\npkgver=0.1.0-r1\narch=noarch\n', 'ascii'),
        Buffer.alloc(48, 0x7f),
    ]));

    const dataTar = tar(PAYLOAD);

    return Buffer.concat([
        sig,
        adbControl, Buffer.alloc(BLOCK, 0),
        zlib.gzipSync(dataTar), Buffer.alloc(BLOCK, 0),
    ]);
}

/** OpenWrt 22.03 ipk: gzipped tar wrapping the three debian members. */
function makeIpk() {
    const controlTar = zlib.gzipSync(tar([['control', CONTROL]]));
    const dataTar = zlib.gzipSync(tar(PAYLOAD.map(([n, c, m]) => ['./' + n, c, m])));
    const outer = tar([
        ['./debian-binary', '2.0\n'],
        ['./control.tar.gz', controlTar],
        ['./data.tar.gz', dataTar],
    ]);
    return zlib.gzipSync(outer);
}

/** Legacy ar ipk. */
function makeArIpk() {
    const members = [
        { name: 'debian-binary', data: Buffer.from('2.0\n') },
        { name: 'control.tar.gz', data: zlib.gzipSync(tar([['control', CONTROL]])) },
        { name: 'data.tar.gz', data: zlib.gzipSync(tar(PAYLOAD.map(([n, c, m]) => ['./' + n, c, m]))) },
    ];
    const parts = [Buffer.from('!<arch>\n', 'ascii')];
    for (const m of members) {
        const h = Buffer.alloc(60, 0x20);
        h.write((m.name + '/').padEnd(16, ' '), 0, 16, 'ascii');
        h.write('0'.padEnd(12, ' '), 16, 12, 'ascii');
        h.write('0'.padEnd(6, ' '), 28, 6, 'ascii');
        h.write('0'.padEnd(6, ' '), 34, 6, 'ascii');
        h.write(String(m.data.length).padEnd(10, ' '), 48, 10, 'ascii');
        h.write('`\n', 58, 2, 'ascii');
        parts.push(h, m.data);
        if (m.data.length % 2) parts.push(Buffer.from('\n'));
    }
    return Buffer.concat(parts);
}

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pkgfmt-'));
const cases = [
    ['apkv2 synthetic', 'x.apk', makeApkv2()],
    ['apkv3 synthetic', 'x.apk', makeApkv3()],
    ['ipk 22.03 synthetic', 'x.ipk', makeIpk()],
    ['ipk ar legacy', 'x.ipk', makeArIpk()],
];

// A deliberately broken file: the checker must say so rather than pass it.
const bad = path.join(tmp, 'broken.apk');
fs.writeFileSync(bad, Buffer.concat([
    Buffer.from('debian-binary\n', 'ascii'), Buffer.alloc(32, 0x55),
]));
cases.push(['broken container (must FAIL)', 'broken.apk', null]);

let failures = 0;

for (const [label, name, buf] of cases) {
    const file = path.join(tmp, name);
    if (buf) fs.writeFileSync(file, buf);

    let out = '';
    let status = 0;
    try {
        out = execFileSync(process.execPath, [CHECKER, file], { encoding: 'utf8' });
    } catch (e) {
        out = String((e.stdout || '') + (e.stderr || ''));
        status = e.status === undefined ? 1 : e.status;
    }

    const expectFail = label.includes('must FAIL');
    const ok = expectFail ? status !== 0 : /RESULT: OK/.test(out);
    if (!ok) failures++;

    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}`);
    const container = out.split('\n').find((l) => l.includes('container:'));
    const result = out.split('\n').find((l) => l.includes('RESULT:'));
    if (container) console.log('        ' + container.trim());
    if (result) console.log('        ' + result.trim());
    if (!ok) {
        out.split('\n').filter((l) => l.trim().startsWith('- ')).slice(0, 6)
            .forEach((l) => console.log('        ' + l.trim()));
    }
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(`\n${cases.length} fixture(s), ${failures} failure(s)`);
process.exit(failures === 0 ? 0 : 1);
