/**
 * Inspect built packages: verify structure and list contents.
 * Uses only zlib, so it works anywhere without tar/ar binaries.
 *
 *   node scripts/check-package.js dist/gl-ai-agent_0.1.0_all.ipk
 *   node scripts/check-package.js dist/gl-ai-agent-0.1.0-r1.apk
 *
 * Options let a caller point the assertions at a tree the platform's own
 * package manager produced, which is strictly better evidence than this
 * script's own reading of the container:
 *
 *   --installed-root DIR   the apk was installed into DIR by apk-tools; assert
 *                          against what actually landed on disk there
 *   --apk-listing FILE     same, but from a saved listing: one entry per line,
 *                          either "path" or "mode size path" (stat -c '%a %s %n')
 *
 * Both are optional. Without them the container is decoded directly, which is
 * enough for the gzip-based formats and for a local APKv2, but APKv3's data
 * stream may be zstd - decodable only on a Node build with zstd support.
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ---------------------------------------------------------------------------
// stream probing
// ---------------------------------------------------------------------------

const isGzip = (b, i) => b[i] === 0x1f && b[i + 1] === 0x8b && b[i + 2] === 0x08;
const isZstd = (b, i) => b[i] === 0x28 && b[i + 1] === 0xb5 && b[i + 2] === 0x2f && b[i + 3] === 0xfd;

/**
 * apk-tools 3 containers open with "ADB" plus a format-version character.
 *
 * Everything after that is compressed ADB - apk's own database encoding, not
 * tar. Verified against a package from the OpenWrt 25.12 feed: no gzip, zstd or
 * ustar bytes anywhere in the file, and the only readable string is the magic
 * itself. This checker therefore cannot read such a package's contents, and does
 * not pretend to; apk-tools is asked instead (see --installed-root below).
 */
const isAdb = (b) => b.subarray(0, 3).toString('ascii') === 'ADB'
    && b[3] >= 0x21 && b[3] <= 0x7e;

/** Node grew zstd support in 22.15/23.8; older runtimes simply cannot read it. */
const zstdSupported = () => typeof zlib.zstdDecompressSync === 'function';

/**
 * Every offset a stream could plausibly begin at.
 *
 * Compressed streams are found by their magic, uncompressed ones by a ustar
 * header sitting on a 512-byte boundary. Magic bytes also occur inside
 * compressed data, so candidates are filtered later by whether they actually
 * decode into tar members - the same "classify by content" rule the rest of
 * this script uses.
 */
function streamCandidates(raw) {
    const found = [];
    let zstdSeen = 0;
    for (let i = 0; i + 4 <= raw.length; i++) {
        if (isGzip(raw, i)) found.push({ off: i, kind: 'gzip' });
        else if (isZstd(raw, i)) {
            zstdSeen++;
            found.push({ off: i, kind: 'zstd' });
        }
    }
    for (let off = 0; off + 512 <= raw.length; off += 512) {
        if (raw.subarray(off + 257, off + 262).toString('ascii') === 'ustar') {
            found.push({ off, kind: 'plain-tar' });
        }
    }
    found.sort((a, b) => a.off - b.off || (a.kind === 'plain-tar' ? 1 : -1));
    return { found, zstdSeen };
}

/**
 * Parse the records of a PAX extended header member.
 *
 * Records look like "27 APK-TOOLS.checksum.SHA1=...\n": a decimal byte length,
 * a space, then "key=value". apk uses these to carry per-file checksums, and
 * they also carry "path" when a name does not fit the 100-byte ustar field.
 */
function parsePax(buf) {
    const out = {};
    let off = 0;
    while (off < buf.length) {
        const sp = buf.indexOf(0x20, off);
        if (sp < 0) break;
        const len = parseInt(buf.subarray(off, sp).toString('ascii'), 10);
        if (!Number.isFinite(len) || len <= 0 || off + len > buf.length) break;
        const rec = buf.subarray(sp + 1, off + len).toString('utf8').replace(/\n$/, '');
        const eq = rec.indexOf('=');
        if (eq > 0) out[rec.slice(0, eq)] = rec.slice(eq + 1);
        off += len;
    }
    return out;
}

function untar(buf) {
    const out = [];
    let off = 0;
    let pendingLongName = null;
    let pendingPax = null;

    while (off + 512 <= buf.length) {
        const h = buf.subarray(off, off + 512);
        if (h.every((b) => b === 0)) break;

        const magic = h.subarray(257, 263).toString('ascii');
        const name = h.subarray(0, 100).toString('utf8').replace(/\0.*$/, '');
        const size = parseInt(h.subarray(124, 136).toString('ascii').replace(/\0.*$/, '').trim(), 8) || 0;
        const type = h.subarray(156, 157).toString('ascii');
        const mode = parseInt(h.subarray(100, 108).toString('ascii').replace(/\0.*$/, '').trim(), 8) || 0;
        off += 512;

        // Extended headers describe the member that follows them. They are
        // metadata, not payload: a real Alpine package leads with
        // "PaxHeaders/.PKGINFO", which - treated as an entry - looks exactly
        // like a .PKGINFO member and shadows the real one.
        if (type === 'x' || type === 'g') {
            if (type === 'x') pendingPax = parsePax(buf.subarray(off, off + size));
            off += Math.ceil(size / 512) * 512;
            continue;
        }

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
        if (pendingPax && pendingPax.path) full = pendingPax.path;
        pendingPax = null;

        if (type === '0' || type === '' || type === '1' || type === '7') {
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
 * The streams differ in ways that matter here:
 *
 *   signature  raw APK signature record - no gzip magic at all
 *   control    ADB format (apk-tools' own database format), NOT tar
 *   data       the installable tree, as a tar, in one of several framings
 *
 * So only the data stream can be read with a tar reader, and `.PKGINFO` is not
 * available to this checker at all - it lives in the control stream, encoded as
 * ADB. That is fine: the assertions this script makes are about the payload, and
 * CI additionally asks apk-tools itself whether the package is well formed.
 *
 * Streams are classified by their contents rather than by any label, because
 * neither the ADB control stream nor the signature is self-describing, and the
 * data stream's compression is the builder's choice (gzip, zstd, or none).
 *
 * @returns {{data: Array, streams: string[], isV3Signature: boolean,
 *            candidates: number, unreadable: number,
 *            zstdSeen: number, zstdUnsupported: boolean}|null}
 *          null when this does not look like a v3 container
 */
function readApkv3(raw) {
    const isV3Signature = raw.subarray(0, 14).toString('ascii') === 'debian-binary\n';
    const { found, zstdSeen } = streamCandidates(raw);

    let data = null;
    const streams = [];
    let unreadable = 0;
    let zstdUnsupported = false;

    for (const { off, kind } of found) {
        let plain;
        try {
            if (kind === 'gzip') plain = zlib.gunzipSync(raw.subarray(off));
            else if (kind === 'zstd') {
                if (!zstdSupported()) {
                    zstdUnsupported = true;
                    unreadable++;
                    continue;
                }
                plain = zlib.zstdDecompressSync(raw.subarray(off));
            } else plain = raw.subarray(off);
        } catch (e) {
            unreadable++;
            continue;
        }

        let entries;
        try {
            entries = untar(plain);
        } catch (e) {
            unreadable++;
            continue;
        }
        if (!entries.length) {
            // decoded, but holds no tar members: the ADB control stream
            streams.push('adb-or-control');
            continue;
        }

        const names = entries.map((e) => e.name);
        const looksLikePayload = names.some((n) => /(^|\/)data\//.test(n))
            || names.some((n) => /(^|\/)(usr|www|etc)\//.test(n));

        if (looksLikePayload && !data) {
            data = entries;
            streams.push('data' + (kind === 'gzip' ? '' : `(${kind})`));
        } else {
            streams.push('tar-other');
        }
    }

    if (!data && !isV3Signature) return null;
    return {
        data: data || [],
        streams,
        isV3Signature,
        candidates: found.length,
        unreadable,
        zstdSeen,
        zstdUnsupported,
    };
}

/**
 * Payload entries read from a directory apk-tools installed the package into.
 * This is the strongest evidence available: it is what the package manager
 * decided to write, with the modes it wrote.
 */
function entriesFromDir(dir) {
    // Windows cannot represent the executable bit, so a mode read there would be
    // a lie. Report "unknown" (0) instead, which skips the mode assertion rather
    // than failing it for the wrong reason.
    const modesKnown = process.platform !== 'win32';
    const out = [];
    const walk = (rel) => {
        let items;
        try {
            items = fs.readdirSync(path.join(dir, rel), { withFileTypes: true });
        } catch (e) {
            return;
        }
        for (const it of items) {
            const r = rel ? `${rel}/${it.name}` : it.name;
            if (it.isDirectory()) {
                out.push({ name: r, size: 0, mode: 0, dir: true });
                walk(r);
            } else if (it.isFile()) {
                const st = fs.statSync(path.join(dir, r));
                out.push({
                    name: r,
                    size: st.size,
                    mode: modesKnown ? (st.mode & 0o7777) : 0,
                    dir: false,
                });
            }
        }
    };
    walk('');
    return out;
}

/** Payload entries parsed from a saved listing: "path" or "mode size path". */
function entriesFromListing(text) {
    const out = [];
    for (const rawLine of text.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line || line.startsWith('#')) continue;
        const parts = line.split(/\s+/);
        let mode = 0;
        let size = 0;
        let name;
        if (parts.length >= 3 && /^[0-7]{3,4}$/.test(parts[0]) && /^\d+$/.test(parts[1])) {
            mode = parseInt(parts[0], 8);
            size = parseInt(parts[1], 10);
            name = parts.slice(2).join(' ');
        } else {
            name = parts.join(' ');
        }
        name = name.replace(/^\.\//, '');
        // a trailing slash marks a directory in some listings
        const dir = /\/$/.test(name);
        out.push({ name: name.replace(/\/$/, ''), size, mode, dir });
    }
    return out;
}

function report(file, opts = {}) {
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
    const gzipWrapped = isGzip(raw, 0);
    const gzInner = gzipWrapped ? untar(zlib.gunzipSync(raw)) : null;
    const looksLikeApk = gzInner
        && gzInner.some((e) => /(^|\/)\.PKGINFO$/.test(e.name));
    const looksLikeIpk = gzInner
        && gzInner.some((e) => /data\.tar\.gz$/.test(e.name));

    // Not a single gzip stream: try the APKv3 multi-stream container before
    // giving up. This is what `apk mkpkg` (apk-tools 3) produces, and its
    // signature stream has no gzip magic at offset 0, so a plain tar read fails.
    const apkv3 = (!looksLikeApk && !looksLikeIpk && !isAdb(raw)) ? readApkv3(raw) : null;
    const adb = isAdb(raw);

    if (adb) {
        // apk-tools 3's own container. Nothing in it is readable with a tar
        // reader, so the payload assertions can only be made from a listing that
        // apk itself produced.
        console.log('container: APKv3 ADB (.apk, apk-tools 3)');
        console.log('  encoding: ADB, compressed - not tar, so this checker cannot decode it');
        console.log('  apk-tools is the authority on these contents; see --installed-root');
    } else if (apkv3) {
        if (apkv3.isV3Signature) {
            console.log('container: APKv3 multi-stream (.apk, apk-tools 3)');
        } else {
            console.log('container: gzip tar, multi-stream');
        }
        console.log('  stream candidates: ' + apkv3.candidates);
        if (apkv3.streams.length) console.log('  streams: ' + apkv3.streams.join(', '));
        if (apkv3.unreadable) console.log('  undecodable candidates: ' + apkv3.unreadable);
        if (apkv3.zstdSeen) {
            console.log('  zstd stream(s): ' + apkv3.zstdSeen
                + (apkv3.zstdUnsupported
                    ? '  (this Node has no zstd support, so it cannot be decoded here)'
                    : ''));
        }

        // Only the data stream is tar; the control stream is ADB-encoded and is
        // not readable here. The payload assertions below are the point.
        dataEntries = apkv3.data;

        if (!dataEntries.length) {
            console.log('  first 16 bytes: ' + raw.subarray(0, 16).toString('hex'));
        }

        // .PKGINFO is expected to be unreadable in APKv3 (it is inside the ADB
        // control stream). Note it, but do not fail on it: apk-tools itself is
        // asked whether the package is well formed, in the job that builds it.
        const pkginfo = dataEntries.find((e) => /(^|\/)\.PKGINFO$/.test(e.name));
        if (pkginfo) {
            console.log('  --- .PKGINFO ---');
            console.log(
                pkginfo.data.toString('utf8').split('\n')
                    .filter(Boolean).map((l) => '    ' + l).join('\n')
            );
        } else if (dataEntries.length) {
            console.log('  note: .PKGINFO lives in the ADB control stream, which this');
            console.log('        checker does not decode; apk-tools validates it instead');
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
        // maintainer scripts are dot-prefixed members at the archive root; a
        // real abuild package leads with ".post-install" (observed, not guessed)
        const scripts = dataEntries
            .filter((e) => /(^|\/)\.(pre|post)-[a-z]+$/.test(e.name) || /(^|\/)\.trigger$/.test(e.name))
            .map((e) => e.name.replace(/^(\.\/)+/, ''));
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

    // ---- where does the payload come from? --------------------------------
    // Decoding the container is this script's own reading of the bytes. When a
    // caller hands us a tree that apk-tools itself installed, that is better
    // evidence than any decoder: it is what the package manager decided to
    // write, with the modes it wrote. Prefer it, and keep the decoded view as a
    // cross-check rather than as the source of truth.
    let payloadEntries = dataEntries;
    let payloadSource = 'container decode';
    const external = externalPayload(opts, problems);
    if (external) {
        payloadEntries = external.entries;
        payloadSource = external.provenance;
        if (dataEntries.length) crossCheck(dataEntries, external.entries);
    }

    console.log('  --- payload ---');
    console.log('  source: ' + payloadSource
        + (payloadEntries.length ? `  (${payloadEntries.filter((e) => !e.dir).length} files)` : ''));
    let total = 0;
    for (const e of payloadEntries) {
        const n = e.name.replace(/^\.\//, '');
        if (e.dir) continue;
        total += e.size;
        const mode = e.mode ? e.mode.toString(8).padStart(4, '0') : '----';
        console.log(`    ${mode}  ${String(e.size).padStart(7)}  ${n}`);
    }
    console.log(`  payload bytes: ${total}`);

    if (!payloadEntries.length) {
        problems.push(adb
            ? 'this is an ADB container: its contents cannot be read here, so supply '
                + '--installed-root DIR (a tree apk-tools installed) or --apk-listing FILE'
            : 'could not read the payload stream');
    }

    // ---- contract assertions ------------------------------------------
    // Normalise the many prefixes the different writers produce:
    //   "./x"            tar members
    //   "data/x"         our own APKv2 payload
    //   "/x"             apk-tools sometimes stores absolute-looking paths
    //   ".PKGINFO"       apk control metadata at the archive root
    const files = payloadEntries.filter((e) => !e.dir);
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
    const rpc = files.find((e) => strip(e.name) === 'usr/lib/oui-httpd/rpc/gl_ai');
    if (rpc && rpc.mode && (rpc.mode & 0o111) === 0) problems.push('rpc object is not executable');
    if (rpc && !rpc.mode) {
        console.log('  note: no mode recorded for the rpc object in this payload view,');
        console.log('        so its executability was not asserted');
    }

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

/**
 * Payload entries from a source outside the container, if the caller pointed at
 * one. Returns null when neither option was used.
 */
function externalPayload(opts, problems) {
    if (opts.installedRoot) {
        if (!fs.existsSync(opts.installedRoot)) {
            problems.push(`--installed-root ${opts.installedRoot} does not exist`);
            return null;
        }
        const entries = entriesFromDir(opts.installedRoot);
        return {
            entries,
            provenance: `installed tree (apk-tools wrote ${opts.installedRoot})`,
        };
    }
    if (opts.apkListing) {
        if (!fs.existsSync(opts.apkListing)) {
            problems.push(`--apk-listing ${opts.apkListing} does not exist`);
            return null;
        }
        return {
            entries: entriesFromListing(fs.readFileSync(opts.apkListing, 'utf8')),
            provenance: `saved listing (${path.basename(opts.apkListing)})`,
        };
    }
    return null;
}

/**
 * Compare the container's data stream with what actually got installed. They
 * should agree; when they do not, that is worth knowing about, but the installed
 * tree still decides the verdict - extra files there are apk's own database.
 */
function crossCheck(decoded, installed) {
    const strip = (n) => n.replace(/^\.\//, '').replace(/^\/+/, '').replace(/^data\//, '');
    const a = new Set(decoded.filter((e) => !e.dir).map((e) => strip(e.name)));
    const b = new Set(installed.filter((e) => !e.dir).map((e) => strip(e.name)));
    const onlyDecoded = [...a].filter((n) => !b.has(n));
    const onlyInstalled = [...b].filter((n) => !a.has(n));

    if (!onlyDecoded.length && !onlyInstalled.length) {
        console.log('  cross-check: container data stream matches the installed tree');
        return;
    }
    console.log('  cross-check: container data stream vs installed tree differ');
    const show = (label, list) => {
        if (!list.length) return;
        console.log(`    ${label} (${list.length}): ` + list.slice(0, 5).join(', ')
            + (list.length > 5 ? ', ...' : ''));
    };
    // apk keeps its database outside the package, so a handful of extra paths
    // on the installed side is expected rather than alarming.
    show('only in the container', onlyDecoded);
    show('only after install', onlyInstalled);
}

const opts = { installedRoot: null, apkListing: null };
const targets = [];
{
    const argv = process.argv.slice(2);
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const take = (name) => {
            const inline = a.startsWith(name + '=');
            const value = inline ? a.slice(name.length + 1) : argv[++i];
            if (value === undefined) {
                console.error(`option ${name} needs a value`);
                process.exit(2);
            }
            return value;
        };
        if (a === '--installed-root' || a.startsWith('--installed-root=')) {
            opts.installedRoot = take('--installed-root');
        } else if (a === '--apk-listing' || a.startsWith('--apk-listing=')) {
            opts.apkListing = take('--apk-listing');
        } else if (a === '--help' || a === '-h') {
            console.log('usage: node scripts/check-package.js <package> [...]');
            console.log('       [--installed-root DIR] [--apk-listing FILE]');
            process.exit(0);
        } else {
            targets.push(a);
        }
    }
}

if (!targets.length) {
    console.error('usage: node scripts/check-package.js <package> [...]');
    console.error('       [--installed-root DIR] [--apk-listing FILE]');
    process.exit(2);
}
let ok = true;
for (const f of targets) {
    if (!fs.existsSync(f)) {
        console.error(`missing: ${f}`);
        ok = false;
        continue;
    }
    if (!report(f, opts)) ok = false;
}
process.exit(ok ? 0 : 1);
