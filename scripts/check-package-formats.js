/**
 * The package checker is what proves a built package is installable, so it has
 * to be right about every container format it claims to read. A checker that
 * silently mis-reads a format is worse than no checker, and CI is too slow a
 * place to discover that.
 *
 * The fixtures below were each corrected against a real package downloaded from
 * a public feed, because the first versions were written from assumption and
 * were wrong in ways that mattered:
 *
 *   - APKv2: the payload sits at the archive ROOT (no "data/" prefix), scripts
 *     are dot-prefixed at the root, and every member carries a PAX extended
 *     header (checked against lua5.1-lzlib from Alpine 3.20)
 *   - APKv3: apk-tools 3 emits an ADB container - "ADBd" then deflate'd ADB, with
 *     no gzip, zstd or ustar bytes anywhere (checked against 6rd from the
 *     OpenWrt 25.12 feed). It cannot be decoded here, so the checker must say so
 *     and take its verdict from a listing apk-tools produced
 *   - ipk: OpenWrt 22.03 wraps the debian members in a gzipped tar; the ar form
 *     is the older variant
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

/** One PAX extended header record, length-prefixed as the format requires. */
function paxRecord(key, value) {
    const body = ` ${key}=${value}\n`;
    const len = Buffer.byteLength(body) + String(body.length).length;
    return Buffer.from(String(len) + body, 'utf8');
}

/**
 * The leading extended header a real abuild/apk package carries for every
 * member. It is metadata, not payload, and its member name is
 * "PaxHeaders/<real name>" - which ends in the real name, so a tar reader that
 * does not understand type 'x' silently mistakes it for the file it describes.
 */
function paxMember(realName) {
    const rec = paxRecord('APK-TOOLS.checksum.SHA1', 'deadbeef');
    const parts = [header({ name: `PaxHeaders/${realName}`, size: rec.length, type: 'x' }), rec];
    const rem = rec.length % BLOCK;
    if (rem) parts.push(Buffer.alloc(BLOCK - rem, 0));
    return parts;
}

/**
 * A gzipped tar where every member is preceded by its PAX header, matching what
 * `abuild-tar --cut` emits: this is the shape of an actual Alpine .apk.
 */
function tarWithPax(files) {
    const chunks = [];
    for (const [name, content, mode] of files) {
        const data = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
        chunks.push(...paxMember(name));
        chunks.push(header({ name, size: data.length, mode: mode || 0o644 }), data);
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

/**
 * APKv2, in the shape a real package has.
 *
 * Verified against lua5.1-lzlib from the Alpine 3.20 feed: the payload sits at
 * the archive ROOT (no "data/" prefix), maintainer scripts are dot-prefixed
 * members at the root (".post-install", not "scripts/post-install"), and every
 * member is preceded by a PAX extended header. All three were wrong in the first
 * version of this fixture, which is exactly why the reader got them wrong.
 */
function makeApkv2() {
    const body = tarWithPax([
        ['.PKGINFO', 'pkgname = gl-ai-agent\npkgver = 0.1.0-r1\narch = noarch\n'],
        ...PAYLOAD,
        ['.post-install', '#!/bin/sh\nexit 0\n', 0o755],
    ]);
    return zlib.gzipSync(body);
}

/**
 * APKv3 as apk-tools 3 actually writes it: an ADB container.
 *
 * Confirmed against a package from the OpenWrt 25.12 feed - the file opens with
 * "ADBd" and contains no gzip, zstd or ustar bytes at all, so nothing inside it
 * is readable without an ADB decoder. A checker that claimed to read one would
 * be lying, so this fixture asserts the opposite: the container is reported as
 * opaque, and the verdict has to come from a listing apk-tools produced.
 */
function makeAdbApk() {
    const adbBody = Buffer.concat([
        Buffer.from('ADB.pckg', 'ascii'),
        Buffer.from([0x24, 0x06, 0x00, 0x00, 0x00, 0x10, 0x06, 0x00]),
        Buffer.from('gl-ai-agent\u000213\u0002Provides the GL-AI assistant.', 'latin1'),
        Buffer.alloc(96, 0x11),
    ]);
    return Buffer.concat([
        Buffer.from('ADBd', 'ascii'),
        zlib.deflateRawSync(adbBody),
        Buffer.alloc(32, 0x5a),
    ]);
}

/**
 * A multi-stream gzip container holding a tar data stream.
 *
 * No apk-tools release is known to emit this, but the reader supports it and an
 * untested reader is the thing that broke CI in the first place. Kept as a
 * capability test, clearly labelled as synthetic.
 */
function makeApkv3GzipStreams() {
    // A short opaque record stands in for the signature so offset 0 is non-gzip.
    const sig = Buffer.concat([
        Buffer.from('GL-AI-TEST-SIGNATURE\0', 'ascii'),
        Buffer.alloc(64, 0xab),
    ]);

    // The ADB control stream is gzip'd but is not a tar: it decodes to bytes
    // with no members, which is how it gets classified.
    const adbControl = zlib.gzipSync(Buffer.concat([
        Buffer.from('2.0\n', 'ascii'),
        Buffer.from('pkgname=gl-ai-agent\npkgver=0.1.0-r1\narch=noarch\n', 'ascii'),
        Buffer.alloc(48, 0x7f),
    ]));

    return Buffer.concat([
        sig,
        adbControl, Buffer.alloc(BLOCK, 0),
        zlib.gzipSync(tar(PAYLOAD)), Buffer.alloc(BLOCK, 0),
    ]);
}

/** The same, with the data stream zstd-compressed instead of gzip. */
function makeApkv3ZstdStreams() {
    if (typeof zlib.zstdCompressSync !== 'function') return null;
    const sig = Buffer.concat([
        Buffer.from('GL-AI-TEST-SIGNATURE\0', 'ascii'),
        Buffer.alloc(64, 0xab),
    ]);
    return Buffer.concat([
        sig,
        zlib.zstdCompressSync(tar(PAYLOAD)), Buffer.alloc(BLOCK, 0),
    ]);
}

/** A listing of the payload in the form `stat -c '%a %s %n'` prints. */
function listing() {
    return PAYLOAD
        .map(([n, c, m]) => `${(m || 0o644).toString(8)} ${Buffer.byteLength(c)} ./${n}`)
        .join('\n') + '\n';
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

/** An installed tree, as apk-tools would leave one behind. */
function installedTree() {
    const root = path.join(tmp, 'root');
    for (const [n, c, m] of PAYLOAD) {
        const p = path.join(root, n);
        fs.mkdirSync(path.dirname(p), { recursive: true });
        fs.writeFileSync(p, c);
        // An install applies the modes the package recorded, and the checker
        // asserts them on Linux. Without this the fixture would fail there while
        // passing on Windows, where modes are read as unknown.
        try {
            fs.chmodSync(p, m || 0o644);
        } catch (e) { /* Windows cannot; the checker treats modes as unknown */ }
    }
    return root;
}

const listingFile = path.join(tmp, 'listing.txt');
fs.writeFileSync(listingFile, listing());

// Each case: what to point the checker at, and what it must conclude. Names are
// unique per case so a kept fixture directory is not ambiguous.
const cases = [
    { label: 'apkv2 (real shape, PAX headers)', file: 'v2.apk', buf: makeApkv2() },
    { label: 'apkv3 gzip streams (capability)', file: 'v3gzip.apk', buf: makeApkv3GzipStreams() },
    {
        label: 'apkv3 zstd streams (capability)',
        file: 'v3zstd.apk',
        buf: makeApkv3ZstdStreams(),
        skip: typeof zlib.zstdCompressSync !== 'function' && 'Node here has no zstd support',
    },
    {
        label: 'apkv3 ADB container, listing supplied',
        file: 'adb.apk',
        buf: makeAdbApk(),
        args: ['--apk-listing', listingFile],
    },
    {
        label: 'apkv3 ADB container, installed root',
        file: 'adb.apk',
        buf: makeAdbApk(),
        args: ['--installed-root', installedTree()],
    },
    {
        label: 'apkv3 ADB container, nothing supplied (must FAIL)',
        file: 'adb.apk',
        buf: makeAdbApk(),
        expectFail: true,
    },
    {
        label: 'apkv3 ADB container, listing missing a file (must FAIL)',
        file: 'adb.apk',
        buf: makeAdbApk(),
        args: ['--apk-listing', path.join(tmp, 'partial-listing.txt')],
        extra: {
            name: 'partial-listing.txt',
            content: listing().split('\n').filter((l) => !l.includes('tools.lua')).join('\n'),
        },
        expectFail: true,
    },
    {
        // The RPC object must arrive executable or the SDK will not load it: a
        // package that installs cleanly and does nothing. The mode assertion is
        // the only thing standing between that and a release, so it gets a case.
        label: 'rpc object not executable (must FAIL)',
        file: 'adb.apk',
        buf: makeAdbApk(),
        args: ['--apk-listing', path.join(tmp, 'noexec-listing.txt')],
        extra: {
            name: 'noexec-listing.txt',
            content: listing().replace(/^755 (\d+) \.\/usr\/lib\/oui-httpd\/rpc\/gl_ai$/m, '644 $1 ./usr/lib/oui-httpd/rpc/gl_ai'),
        },
        expectFail: true,
    },
    { label: 'ipk 22.03 synthetic', file: 'x.ipk', buf: makeIpk() },
    { label: 'ipk ar legacy', file: 'x.ipk', buf: makeArIpk() },
];

// A deliberately broken file: the checker must say so rather than pass it.
cases.push({
    label: 'unrecognised container (must FAIL)',
    file: 'broken.apk',
    buf: Buffer.concat([Buffer.from('NOT-A-PACKAGE\n', 'ascii'), Buffer.alloc(64, 0x55)]),
    expectFail: true,
});

let failures = 0;
let skipped = 0;

for (const c of cases) {
    // GL_ONLY=<substring> narrows a debugging run to matching fixtures.
    if (process.env.GL_ONLY && !c.label.includes(process.env.GL_ONLY)) continue;
    if (c.skip) {
        skipped++;
        console.log(`  SKIP  ${c.label}  (${c.skip})`);
        continue;
    }
    if (c.extra) fs.writeFileSync(path.join(tmp, c.extra.name), c.extra.content);
    const file = path.join(tmp, c.file);
    if (c.buf) fs.writeFileSync(file, c.buf);

    let out = '';
    let status = 0;
    try {
        out = execFileSync(process.execPath, [CHECKER, file, ...(c.args || [])], { encoding: 'utf8' });
    } catch (e) {
        out = String((e.stdout || '') + (e.stderr || ''));
        status = e.status === undefined ? 1 : e.status;
    }

    const ok = c.expectFail ? status !== 0 : /RESULT: OK/.test(out);
    if (!ok) failures++;

    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${c.label}`);
    const container = out.split('\n').find((l) => l.includes('container:'));
    const source = out.split('\n').find((l) => l.includes('  source:'));
    const result = out.split('\n').find((l) => l.includes('RESULT:'));
    if (container) console.log('        ' + container.trim());
    if (source) console.log('        ' + source.trim());
    if (result) console.log('        ' + result.trim());
    if (!ok) {
        out.split('\n').filter((l) => l.trim().startsWith('- ')).slice(0, 6)
            .forEach((l) => console.log('        ' + l.trim()));
    }
}

// Set GL_KEEP_FIXTURES=1 to leave the generated files behind for inspection.
if (process.env.GL_KEEP_FIXTURES) {
    console.log(`\nfixtures kept in ${tmp}`);
} else {
    fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(`\n${cases.length} fixture(s), ${failures} failure(s)`
    + (skipped ? `, ${skipped} skipped` : ''));
process.exit(failures === 0 ? 0 : 1);