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

/**
 * Read an APKv3 (apk-tools 3) package.
 *
 * APKv3 is a multi-stream container, not a single gzipped tar:
 *
 *     <signature stream> <control stream> <data stream>
 *
 * Each stream is a gzip member whose first file is `debian-binary` holding
 * "2.0\n" followed by the stream's own name, and each is terminated by a
 * 512-byte block of zeros. The signature stream carries no gzip magic - it
 * starts with a raw APK signature record - which is why feeding the whole file
 * to a tar reader fails outright.
 *
 * Which stream holds what matters: `.PKGINFO` and the maintainer scripts live in
 * the CONTROL stream, the installable tree lives in the DATA stream. Reading a
 * fixed stream number would be wrong, so the streams are identified by what
 * their debian-binary says.
 *
 * @returns {{data: Array, control: Array, streams: string[], isV3Signature: boolean,
 *            gzipMembers: number}|null} null when the buffer is not a v3 container
 */
function readApkv3(raw) {
    const isV3Signature = raw.subarray(0, 14).toString('ascii') === 'debian-binary\n';

    const offsets = [];
    for (let i = 0; i + 2 < raw.length; i++) {
        if (raw[i] === 0x1f && raw[i + 1] === 0x8b && raw[i + 2] === 0x08) {
            offsets.push(i);
        }
    }

    let data = null;
    let control = null;
    const streams = [];

    for (const off of offsets) {
        let plain;
        try {
            plain = zlib.gunzipSync(raw.subarray(off));
        } catch (e) {
            continue;                       // not a member we can read; skip it
        }
        let entries;
        try {
            entries = untar(plain);
        } catch (e) {
            continue;
        }
        if (!entries.length) continue;

        const db = entries.find((e) => /(^|\/)debian-binary$/.test(e.name));
        let id = 'data';                    // apk's default stream
        if (db) {
            const lines = db.data.toString('utf8').split('\n').map((s) => s.trim()).filter(Boolean);
            if (lines[1]) id = lines[1];
        }
        streams.push(id);

        if (id === 'data' && !data) data = entries;
        if (id === 'control' && !control) control = entries;
    }

    // Only claim the file when something was actually read, so a non-gzip
    // container (an ar ipk, say) is not misrouted here just because it happened
    // to contain a gzip member somewhere.
    if (!data && !control) {
        if (!isV3Signature) return null;
        return { data: [], control: [], streams, isV3Signature, gzipMembers: offsets.length };
    }

    return {
        data: data || [],
        control: control || [],
        streams,
        isV3Signature,
        gzipMembers: offsets.length,
    };
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

    // Not a single gzip stream: try the APKv3 multi-stream container before
    // giving up. This is what `apk mkpkg` (apk-tools 3) produces, and its
    // signature stream has no gzip magic at offset 0, so a plain tar read fails.
    const apkv3 = (!looksLikeApk && !looksLikeIpk) ? readApkv3(raw) : null;

    if (apkv3) {
        if (apkv3.isV3Signature) {
            console.log('container: APKv3 multi-stream (.apk, apk-tools 3)');
        } else {
            console.log('container: gzip tar, multi-stream');
        }
        console.log('  gzip members found: ' + apkv3.gzipMembers);
        if (apkv3.streams.length) console.log('  streams: ' + apkv3.streams.join(', '));

        // The installable tree is the data stream; the metadata and maintainer
        // scripts live in the control stream.
        dataEntries = apkv3.data;
        controlEntries = apkv3.control;

        if (!dataEntries.length && !controlEntries.length) {
            problems.push('could not read any stream from the package');
            console.log('  first 16 bytes: ' + raw.subarray(0, 16).toString('hex'));
        }

        const pkginfo = controlEntries.find((e) => /(^|\/)\.PKGINFO$/.test(e.name))
            || dataEntries.find((e) => /(^|\/)\.PKGINFO$/.test(e.name));
        if (!pkginfo) {
            problems.push('no .PKGINFO in the control stream');
        } else {
            console.log('  --- .PKGINFO ---');
            console.log(
                pkginfo.data.toString('utf8').split('\n')
                    .filter(Boolean).map((l) => '    ' + l).join('\n')
            );
        }
    } else if (looksLikeApk) {
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
    // Normalise the many prefixes the different writers produce:
    //   "./x"            tar members
    //   "data/x"         our own APKv2 payload
    //   "/x"             apk-tools sometimes stores absolute-looking paths
    //   ".PKGINFO"       apk control metadata at the archive root
    const files = dataEntries.filter((e) => !e.dir);
    const strip = (n) => n
        .replace(/^\.\//, '')
        .replace(/^\/+/, '')
        .replace(/^data\//, '')
        .replace(/^\.\//, '');
    const norm = files.map((e) => strip(e.name));

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
    const rpc = dataEntries.find((e) => strip(e.name) === 'usr/lib/oui-httpd/rpc/gl_ai');
    if (rpc && (rpc.mode & 0o111) === 0) problems.push('rpc object is not executable');

    if (problems.length) {
        console.log('\n  RESULT: FAIL');
        problems.forEach((p) => console.log('    - ' + p));

        // When the payload looks unreadable rather than merely incomplete, the
        // container format is the likely culprit and the raw entries are the
        // only way to tell. Dump enough to diagnose without a full hex view.
        if (norm.length === 0 || problems.some((p) => /unrecognised|no \.PKGINFO/.test(p))) {
            console.log('  --- diagnostics ---');
            console.log('    first 16 bytes: ' + raw.subarray(0, 16).toString('hex'));
            console.log('    file size:      ' + raw.length);
            console.log('    entries read:   ' + dataEntries.length
                + ' (' + files.length + ' files)');
            console.log('    first entries:  '
                + dataEntries.slice(0, 8).map((e) => JSON.stringify(e.name)).join(', '));
        }
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
