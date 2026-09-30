/**
 * Describe the actual shape of an .apk container.
 *
 * CI is the only place a genuine apk-tools package exists, so when the checker
 * cannot read one, this prints what is really inside: every gzip member, what
 * each stream calls itself, and the first few entries of each. That turns a bare
 * "could not read the payload" into something actionable.
 *
 *   node scripts/inspect-apk.js dist/whatever.apk
 */
const fs = require('fs');
const zlib = require('zlib');

const BLOCK = 512;

function untar(buf) {
    const out = [];
    let off = 0;
    let pendingLongName = null;

    while (off + BLOCK <= buf.length) {
        const h = buf.subarray(off, off + BLOCK);
        if (h.every((b) => b === 0)) break;

        const magic = h.subarray(257, 263).toString('ascii');
        const name = h.subarray(0, 100).toString('utf8').replace(/\0.*$/, '');
        const size = parseInt(h.subarray(124, 136).toString('ascii').replace(/\0.*$/, '').trim(), 8) || 0;
        const type = h.subarray(156, 157).toString('ascii');
        off += BLOCK;

        if (type === 'L' || name === '././@LongLink') {
            pendingLongName = buf.subarray(off, off + size).toString('utf8').replace(/\0.*$/, '');
            off += Math.ceil(size / BLOCK) * BLOCK;
            continue;
        }

        let full = name;
        if (pendingLongName) {
            full = pendingLongName;
            pendingLongName = null;
        }

        out.push({ name: full, size, type, data: buf.subarray(off, off + size) });
        off += Math.ceil(size / BLOCK) * BLOCK;
    }
    return out;
}

const file = process.argv[2];
if (!file) {
    console.error('usage: node scripts/inspect-apk.js <package.apk>');
    process.exit(2);
}

const raw = fs.readFileSync(file);
console.log(`file:   ${file}`);
console.log(`size:   ${raw.length} bytes`);
console.log(`head:   ${raw.subarray(0, 32).toString('hex')}`);
console.log(`ascii:  ${JSON.stringify(raw.subarray(0, 32).toString('ascii'))}`);
console.log(`gzip magic at 0: ${raw.subarray(0, 2).toString('hex') === '1f8b'}`);
console.log(`apkv3 signature: ${raw.subarray(0, 14).toString('ascii') === 'debian-binary\n'}`);

// every gzip member in the buffer
const offsets = [];
for (let i = 0; i + 2 < raw.length; i++) {
    if (raw[i] === 0x1f && raw[i + 1] === 0x8b && raw[i + 2] === 0x08) offsets.push(i);
}
console.log(`\ngzip members: ${offsets.length}  at offsets [${offsets.slice(0, 10).join(', ')}]`);

offsets.forEach((off, i) => {
    console.log(`\n--- member ${i} @ ${off} ---`);
    let plain;
    try {
        plain = zlib.gunzipSync(raw.subarray(off));
    } catch (e) {
        console.log(`  gunzip failed: ${e.message}`);
        return;
    }
    console.log(`  decompressed: ${plain.length} bytes`);
    const entries = untar(plain);
    console.log(`  tar entries: ${entries.length}`);
    entries.slice(0, 8).forEach((e) => {
        const kind = e.type === '5' ? 'dir ' : 'file';
        console.log(`    ${kind} ${JSON.stringify(e.name)} (${e.size})`);
    });
    const db = entries.find((e) => /(^|\/)debian-binary$/.test(e.name));
    if (db) {
        console.log(`  debian-binary: ${JSON.stringify(db.data.toString('utf8'))}`);
    }
    const names = entries.map((e) => e.name);
    for (const probe of ['.PKGINFO', 'data/', 'scripts/']) {
        const hit = names.filter((n) => n.includes(probe)).length;
        console.log(`  entries matching ${JSON.stringify(probe)}: ${hit}`);
    }
});
