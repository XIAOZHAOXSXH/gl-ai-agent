/**
 * Inspect built packages: verify structure and list contents.
 * Uses only zlib, so it works anywhere without tar/ar binaries.
 *
 *   node scripts/check-package.js dist/gl-ai-agent_0.1.0_all.ipk
 *   node scripts/check-package.js dist/gl-ai-agent-0.1.0-r1.apk
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

function untar(buf) {
    const out = [];
    let off = 0;
    let pendingLongName = null;

    while (off + 512 <= buf.length) {
        const h = buf.subarray(off, off + 512);
        if (h.every((b) => b === 0)) break;

        const magic = h.subarray(257, 263).toString('ascii');
        const name = h.subarray(0, 100).toString('utf8').replace(/\0.*$/, '');
        const size = parseInt(h.subarray(124, 136).toString('ascii').replace(/\0.*$/, '').trim(), 8) || 0;
        const type = h.subarray(156, 157).toString('ascii');
        const mode = parseInt(h.subarray(100, 108).toString('ascii').replace(/\0.*$/, '').trim(), 8) || 0;
        off += 512;

        // GNU tar stores a path over 100 bytes as a "././@LongLink" member whose
        // payload is the real name; the following header holds a truncated one.
        // The ustar prefix field is NOT used by GNU, so reading it there yields
        // whatever bytes happen to sit in the header - which is how members
        // acquired garbage names.
        if (type === 'L' || name === '././@LongLink') {
            pendingLongName = buf.subarray(off, off + size).toString('utf8').replace(/\0.*$/, '');
            off += Math.ceil(size / 512) * 512;
            continue;
        }

        let full = name;
        if (pendingLongName) {
            full = pendingLongName;
            pendingLongName = null;
        } else if (magic === 'ustar\0' || magic === 'ustar ') {
            // only ustar (POSIX) uses the prefix field
            const prefix = h.subarray(345, 500).toString('utf8').replace(/\0.*$/, '');
            if (prefix) full = `${prefix}/${name}`;
        }

        if (type === '0' || type === '') {
            out.push({ name: full, size, mode, data: buf.subarray(off, off + size), dir: false });
        } else {
            out.push({ name: full, size: 0, mode, dir: true });
        }
        off += Math.ceil(size / 512) * 512;
    }
    return out;
}

/** Parse an ar archive (the .ipk container). */
function unar(buf) {
    if (buf.subarray(0, 8).toString('ascii') !== '!<arch>\n') return null;
    const members = [];
    let off = 8;
    while (off + 60 <= buf.length) {
        const h = buf.subarray(off, off + 60);
        const name = h.subarray(0, 16).toString('ascii').trim().replace(/\/$/, '');
        const size = parseInt(h.subarray(48, 58).toString('ascii').trim(), 10);
        if (!Number.isFinite(size)) break;
        off += 60;
        members.push({ name, data: buf.subarray(off, off + size) });
        off += size + (size % 2);
    }
    return members;
}

function report(file) {
    console.log(`\n===== ${path.basename(file)} (${(fs.statSync(file).size / 1024).toFixed(1)} KB) =====`);
    const raw = fs.readFileSync(file);
    const problems = [];

    const members = unar(raw);
    let dataEntries = [];
    let controlEntries = [];

    // Both formats are gzipped tars, so the magic byte alone cannot tell them
    // apart: an .apk and an OpenWrt 22.03 .ipk start with the same 1f 8b, and
    // guessing from that sent every apk down the ipk path. Decide by content
    // instead - an apk carries .PKGINFO at its root, an ipk carries the three
    // debian members.
    const isGzip = raw.subarray(0, 2).toString('hex') === '1f8b';
    const gzInner = isGzip ? untar(zlib.gunzipSync(raw)) : null;
    const looksLikeApk = gzInner
        && gzInner.some((e) => /(^|\/)\.PKGINFO$/.test(e.name));
    const looksLikeIpk = gzInner
        && gzInner.some((e) => /data\.tar\.gz$/.test(e.name));

    if (looksLikeApk) {
        console.log('container: gzip tar (.apk, APKv2)');
        dataEntries = gzInner;
        const pkginfo = dataEntries.find((e) => /(^|\/)\.PKGINFO$/.test(e.name));
        if (!pkginfo) problems.push('no .PKGINFO');
        else {
            console.log('  --- .PKGINFO ---');
            console.log(
                pkginfo.data.toString('utf8').split('\n')
                    .filter(Boolean).map((l) => '    ' + l).join('\n')
            );
        }
        // maintainer scripts are dot-prefixed members at the archive root
        const scripts = dataEntries
            .filter((e) => /^\.\/(\.(pre|post)[a-z-]+)$/.test(e.name))
            .map((e) => e.name.replace(/^\.\//, ''));
        if (scripts.length) console.log('  scripts: ' + scripts.join(', '));
    } else if (looksLikeIpk) {
        // OpenWrt 22.03 / GL firmware .ipk is a gzipped tar holding the same
        // three members an ar container would. Confirmed against a package from
        // this device's own feed; opkg rejects the ar form on this firmware.
        console.log('container: gzip tar (.ipk, OpenWrt 22.03 variant)');
        const outer = gzInner;
        console.log('  members: ' + outer.map((e) => e.name.replace(/^\.\//, '')).join(', '));
        const dataTar = outer.find((e) => /data\.tar\.gz$/.test(e.name));
        const ctrlTar = outer.find((e) => /control\.tar\.gz$/.test(e.name));
        const debian = outer.find((e) => /debian-binary$/.test(e.name));
        if (!dataTar) problems.push('no data.tar.gz');
        if (!ctrlTar) problems.push('no control.tar.gz');
        if (!debian) problems.push('no debian-binary');
        else if (debian.data.toString('ascii').trim() !== '2.0') {
            problems.push('debian-binary is not "2.0"');
        }
        if (dataTar) dataEntries = untar(zlib.gunzipSync(dataTar.data));
        if (ctrlTar) controlEntries = untar(zlib.gunzipSync(ctrlTar.data));
    } else if (raw.subarray(0, 8).toString('ascii') === '!<arch>\n') {
        console.log('container: ar (.ipk, legacy variant)');
        const arMembers = unar(raw);
        console.log('  members: ' + arMembers.map((m) => m.name).join(', '));
        const dataTar = arMembers.find((m) => m.name === 'data.tar.gz');
        const ctrlTar = arMembers.find((m) => m.name === 'control.tar.gz');
        if (!dataTar) problems.push('no data.tar.gz');
        if (!ctrlTar) problems.push('no control.tar.gz');
        if (dataTar) dataEntries = untar(zlib.gunzipSync(dataTar.data));
        if (ctrlTar) controlEntries = untar(zlib.gunzipSync(ctrlTar.data));
    } else {
        problems.push('unrecognised container (not gzip tar or ar)');
    }

    const control = controlEntries.find((e) => e.name.includes('control'));
    if (control) {
        console.log('  --- control ---');
        console.log(control.data.toString('utf8').split('\n').map((l) => '    ' + l).join('\n'));
    }
    for (const f of controlEntries.filter((e) => !e.name.includes('control'))) {
        console.log(`  control script: ${f.name} mode=${f.mode.toString(8)}`);
    }

    console.log('  --- payload ---');
    let total = 0;
    for (const e of dataEntries) {
        const n = e.name.replace(/^\.\//, '');
        if (e.dir) continue;
        total += e.size;
        console.log(`    ${e.mode.toString(8).padStart(4, '0')}  ${String(e.size).padStart(7)}  ${n}`);
    }
    console.log(`  payload bytes: ${total}`);

    // ---- contract assertions ------------------------------------------
    // Normalise: tar members use a "./" prefix, and APK payloads live under
    // "data/" (with control scripts under "scripts/").
    const files = dataEntries.filter((e) => !e.dir);
    const names = files.map((e) => e.name.replace(/^\.\//, ''));
    /** Strip the APK data/ prefix so both formats assert against one list. */
    const norm = names.map((n) => (n.startsWith('data/') ? n.slice(5) : n));

    if (process.env.GL_DEBUG_PACKAGE) {
        console.log('  --- debug: normalised names ---');
        norm.forEach((n) => console.log('    ' + JSON.stringify(n)));
    }

    const need = [
        // the SDK fetches the uncompressed path; nginx gzip_static serves the .gz
        'www/views/gl-sdk4-ui-gl-ai.common.js',
        'www/views/gl-sdk4-ui-gl-ai.common.js.gz',
        'www/js/gl-ai-agent-boot.js',
        'usr/share/oui/menu.d/gl-ai.json',
        'usr/lib/oui-httpd/rpc/gl_ai',
        'usr/share/gl-validator.d/gl_ai.lua',
        'usr/lib/lua/glai/agent.lua',
        'usr/lib/lua/glai/tools.lua',
        'usr/lib/lua/glai/llm.lua',
        'usr/lib/lua/glai/rpc_entry.lua',
    ];
    for (const n of need) {
        if (!norm.includes(n)) problems.push(`missing ${n}`);
    }
    if (!norm.some((n) => /^www\/i18n\/gl-sdk4-ui-gl-ai\.[a-z-]+\.json$/.test(n))) {
        problems.push('no i18n files');
    }
    // The agent deliberately adds no nginx location: streaming is delivered by
    // polling the RPC object, so installing requires no web-server change.
    if (norm.some((n) => n.startsWith('etc/nginx/'))) {
        problems.push('unexpected nginx config in payload (agent must not need one)');
    }
    const rpc = dataEntries.find(
        (e) => e.name.replace(/^\.\//, '').replace(/^data\//, '') === 'usr/lib/oui-httpd/rpc/gl_ai'
    );
    if (rpc && (rpc.mode & 0o111) === 0) problems.push('rpc object is not executable');

    if (problems.length) {
        console.log('\n  RESULT: FAIL');
        problems.forEach((p) => console.log('    - ' + p));
        return false;
    }
    console.log('\n  RESULT: OK');
    return true;
}

const files = process.argv.slice(2);
if (!files.length) {
    console.error('usage: node scripts/check-package.js <package> [...]');
    process.exit(2);
}
let ok = true;
for (const f of files) {
    if (!fs.existsSync(f)) {
        console.error(`missing: ${f}`);
        ok = false;
        continue;
    }
    if (!report(f)) ok = false;
}
process.exit(ok ? 0 : 1);
