/**
 * Build an OpenWrt .ipk (opkg) package.
 *
 * Container format, verified against a package from this device's own feed
 * (fw.gl-inet.cn / OpenWrt 22.03.4): the .ipk is a *gzipped tar* holding three
 * members -
 *
 *     ./debian-binary      "2.0\n"
 *     ./control.tar.gz     the control files
 *     ./data.tar.gz        the payload tree
 *
 * That variant starts with the gzip magic 1f 8b, not the ar magic "!<arch>".
 * opkg's pkg_init_from_file rejects the ar form outright ("Malformed package
 * file"), so the outer gzip is not cosmetic here - it is the accepted layout.
 *
 *   node scripts/build-ipk.js
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { execFileSync } = require('child_process');
const { tarGz, rmrf, copyDir, applyModes } = require('./lib/tar');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'package/data');
const CONTROL = path.join(ROOT, 'package/control');
const pkg = require(path.join(ROOT, 'package.json'));

const NAME = pkg.name;
const VERSION = pkg.version;
const ARCH = 'all';                       // pure Lua + assets: architecture independent
const STAGE = path.join(ROOT, '.pkgstage');
const DIST = path.join(ROOT, 'dist');
const OUT = path.join(DIST, `${NAME}_${VERSION}_${ARCH}.ipk`);

/** Executables vs data inside the payload tree. */
function modeFor(rel) {
    if (rel.startsWith('etc/init.d/')) return 0o755;
    if (rel.startsWith('usr/sbin/')) return 0o755;
    if (rel.startsWith('usr/bin/')) return 0o755;
    if (rel.startsWith('usr/lib/oui-httpd/rpc/')) return 0o755;
    if (rel.endsWith('.sh')) return 0o755;
    return 0o644;
}

function controlModeFor(rel) {
    return ['postinst', 'prerm', 'postrm', 'preinst'].includes(rel) ? 0o755 : 0o644;
}

/**
 * Wrap pre-built members in the outer gzipped tar.
 * `modeFor` here applies to the three container entries, which are plain files.
 */
function wrapIpk(members) {
    const tmp = path.join(ROOT, '.ipkwrap');
    rmrf(tmp);
    fs.mkdirSync(tmp, { recursive: true });
    for (const [name, src] of members) {
        fs.copyFileSync(src, path.join(tmp, name));
        fs.chmodSync(path.join(tmp, name), 0o644);
    }
    const archive = path.join(ROOT, '.ipkwrap.tar.gz');
    tarGz(tmp, archive, () => 0o644);
    const outer = fs.readFileSync(archive);
    rmrf(tmp);
    fs.rmSync(archive, { force: true });
    return outer;
}

// ---- stage ---------------------------------------------------------------
rmrf(STAGE);
fs.mkdirSync(DIST, { recursive: true });
copyDir(DATA, STAGE);
rmrf(path.join(STAGE, 'CONTROL'));

// Build the UI first: the package must contain the .js and its .gz.
execFileSync(process.execPath, [path.join(ROOT, 'scripts/build-ui.js')], { stdio: 'inherit' });

fs.mkdirSync(DIST, { recursive: true });

// ---- control -------------------------------------------------------------
const CONTROL_STAGE = path.join(ROOT, '.controlstage');
rmrf(CONTROL_STAGE);
fs.mkdirSync(CONTROL_STAGE, { recursive: true });

let controlText = fs.readFileSync(path.join(CONTROL, 'control'), 'utf8');
controlText = controlText.replace(/^Version: .+$/m, `Version: ${VERSION}`);
controlText = controlText.replace(/^Architecture: .+$/m, `Architecture: ${ARCH}`);
fs.writeFileSync(path.join(CONTROL_STAGE, 'control'), controlText, 'utf8');
for (const f of ['postinst', 'prerm', 'postrm', 'preinst']) {
    const src = path.join(CONTROL, f);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(CONTROL_STAGE, f));
}
applyModes(CONTROL_STAGE, (rel) =>
    ['postinst', 'prerm', 'postrm', 'preinst'].includes(rel)
);
applyModes(STAGE, modeFor);

// ---- assemble ------------------------------------------------------------
// Inner tarballs are built as files, then wrapped in the outer gzipped tar.
//
// The mode callbacks matter: the tar bundled with Windows cannot express file
// modes, so lib/tar falls back to writing ustar itself and needs to be told the
// modes. On the CI runners GNU tar is present and uses the on-disk modes set by
// applyModes above, so the callbacks are simply ignored there.
const controlTar = path.join(ROOT, '.control.tar.gz');
const dataTar = path.join(ROOT, '.data.tar.gz');
tarGz(CONTROL_STAGE, controlTar, (rel) =>
    (['postinst', 'prerm', 'postrm', 'preinst'].includes(rel) ? 0o755 : 0o644)
);
tarGz(STAGE, dataTar, (rel, isDir) => (isDir ? 0o755 : modeFor(rel)));

const debian = path.join(ROOT, '.debian-binary');
fs.writeFileSync(debian, '2.0\n', 'ascii');

const ipk = wrapIpk([
    ['debian-binary', debian],
    ['control.tar.gz', controlTar],
    ['data.tar.gz', dataTar],
]);
fs.writeFileSync(OUT, ipk);

rmrf(STAGE);
rmrf(CONTROL_STAGE);
rmrf(path.join(ROOT, '.ipkwrap'));
for (const f of [controlTar, dataTar, debian]) fs.rmSync(f, { force: true });

console.log(`built ${path.relative(ROOT, OUT)}  ${(ipk.length / 1024).toFixed(1)} KB`);
