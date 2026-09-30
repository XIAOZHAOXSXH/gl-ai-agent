/** Extract the inner tarballs of an .ipk so an external tar can validate them. */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const file = process.argv[2];
const outDir = process.argv[3] || path.join(path.dirname(file), 'extracted');
const buf = fs.readFileSync(file);
fs.mkdirSync(outDir, { recursive: true });

let off = 8;
const members = [];
while (off + 60 <= buf.length) {
    const h = buf.subarray(off, off + 60);
    const name = h.subarray(0, 16).toString('ascii').trim().replace(/\/$/, '');
    const size = parseInt(h.subarray(48, 58).toString('ascii').trim(), 10);
    if (!Number.isFinite(size)) break;
    off += 60;
    members.push({ name, data: buf.subarray(off, off + size) });
    off += size + (size % 2);
}

for (const m of members) {
    const dest = path.join(outDir, m.name);
    fs.writeFileSync(dest, m.data);
    console.log(`${m.name}: ${m.data.length} bytes`);
    if (m.name.endsWith('.tar.gz')) {
        const tarPath = dest.replace(/\.gz$/, '');
        fs.writeFileSync(tarPath, zlib.gunzipSync(m.data));
        console.log(`  -> ${path.basename(tarPath)}: ${fs.statSync(tarPath).size} bytes`);
    }
}
