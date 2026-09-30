const fs = require('fs');
const zlib = require('zlib');

/** gzip a file, writing <src>.gz next to it. Returns the output path. */
function gzipFile(src, dest) {
    const out = dest || src + '.gz';
    const buf = zlib.gzipSync(fs.readFileSync(src), { level: 9 });
    fs.writeFileSync(out, buf);
    return { path: out, size: buf.length };
}

module.exports = { gzipFile };
