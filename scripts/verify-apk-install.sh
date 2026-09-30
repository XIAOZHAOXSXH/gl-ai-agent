#!/bin/sh
# Install the built .apk into a scratch root with apk-tools, and record what
# landed there, so `check-package.js --installed-root` can assert against the
# real result.
#
# Why this exists: an APKv3 package is an ADB container - "ADBd" followed by
# deflated ADB, with no gzip, zstd or ustar bytes anywhere (verified against a
# package from the OpenWrt 25.12 feed). Nothing inside it can be read with a tar
# reader, so apk-tools itself is the only authority on its contents. Installing
# into a throwaway root is both the check and the proof: it is the same
# operation a router performs.
#
# Needs apk-tools v3, so it runs in the Alpine CI job, not on a workstation.
#
# The Depends names in the control file (libc, lua, uci, libubus-lua) are
# OpenWrt packages and do not exist in an Alpine container, so empty stub
# packages are built for them to satisfy the transaction. The stubs install one
# marker file each, under a path that is filtered out of the listing.
#
#   sh scripts/verify-apk-install.sh dist/gl-ai-agent-0.1.0-r1.apk [root] [listing-out]

set -eu

apk_file="${1:?usage: verify-apk-install.sh <package.apk> [root] [listing-out]}"
root="${2:-/tmp/apkroot}"
listing_out="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"
control="$here/../package/control/control"
work="${root}-work"

echo "apk:    $(apk --version 2>&1 | head -1)"
echo "target: $apk_file"

# ---- dependency stubs ----------------------------------------------------
deps="$(sed -n 's/^Depends:[[:space:]]*//p' "$control" | tr ',' ' ')"
pkg_name="$(sed -n 's/^Package:[[:space:]]*//p' "$control")"

rm -rf "$work" "$root"
mkdir -p "$work/stub-tree/usr/share/gl-ai-ci-stubs" "$root"

stubs=""
for d in $deps; do
    # A marker file, because a package with no files at all may not be packable.
    : > "$work/stub-tree/usr/share/gl-ai-ci-stubs/$d"
    if apk mkpkg \
        --info "name:$d" \
        --info "version:0-r0" \
        --info "arch:noarch" \
        --info "description:CI stub for a router-side dependency" \
        --files "$work/stub-tree" \
        --output "$work/$d.apk" > "$work/stub-$d.log" 2>&1; then
        stubs="$stubs $work/$d.apk"
    else
        echo "note: could not build a stub for $d:"
        tail -3 "$work/stub-$d.log" | sed 's/^/      /'
    fi
done
echo "depends:${deps:- none}"
echo "stubs:  ${stubs:- none}"

# ---- install -------------------------------------------------------------
# Flag sets are tried in order because this runs against whatever apk-tools the
# job's image ships, and the exact spelling of "do not run scripts here" and
# "do not fail on a broken world" has moved between releases. The first set that
# works is reported, and every failure is printed rather than swallowed.
installed=""
for flags in \
    "--initdb --allow-untrusted --no-network --no-scripts" \
    "--initdb --allow-untrusted --no-network" \
    "--initdb --allow-untrusted --no-network --force-broken-world" \
    "--initdb --allow-untrusted --no-network --force-depends" \
    "--initdb --allow-untrusted --no-network --force-broken-world --force-depends"
do
    rm -rf "$root"
    mkdir -p "$root"
    # shellcheck disable=SC2086  # the flag sets and stub list are meant to split
    if apk add --root "$root" $flags "$apk_file" $stubs > "$work/add.log" 2>&1; then
        installed="$flags"
        break
    fi
    echo "attempt failed [$flags]:"
    tail -6 "$work/add.log" | sed 's/^/      /'
done

if [ -z "$installed" ]; then
    echo "FAIL: apk could not install $apk_file into $root" >&2
    exit 1
fi
echo "installed with: apk add --root $root $installed"

# apk's own record of the package - an independent cross-check of the tree.
echo "--- apk info -L $pkg_name ---"
apk --root "$root" info --no-network -L "$pkg_name" 2>&1 || true

# ---- what actually landed ------------------------------------------------
# apk's database and the stub markers are not part of the package payload.
find "$root" -type f \
    | sed "s#^$root/##" \
    | grep -v '^lib/apk/' \
    | grep -v '^etc/apk/' \
    | grep -v '^usr/share/gl-ai-ci-stubs/' \
    | sort > "$work/files.txt" || true

find "$root" -type f -exec stat -c '%a %s %n' {} + \
    | sed "s# $root/# #" \
    | grep -v ' lib/apk/' \
    | grep -v ' etc/apk/' \
    | grep -v ' usr/share/gl-ai-ci-stubs/' \
    | sort -k3 > "$work/listing.txt" || true

echo "--- files on disk (mode size path) ---"
cat "$work/listing.txt"
echo "files: $(wc -l < "$work/files.txt")"

if [ -n "$listing_out" ]; then
    cp "$work/listing.txt" "$listing_out"
    echo "listing written to $listing_out"
fi

exit 0
