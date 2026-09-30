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
#   sh scripts/verify-apk-install.sh dist/gl-ai-agent-0.1.0-r1.apk [root] [listing-out]

set -eu

apk_file="${1:?usage: verify-apk-install.sh <package.apk> [root] [listing-out]}"
root="${2:-/tmp/apkroot}"
listing_out="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"
control="$here/../package/control/control"
work="${root}-work"

# apk is given an absolute path: a bare relative path is a package *spec*, and
# whether it is read as a file is one more thing that varies between releases.
case "$apk_file" in
    /*) : ;;
    *) apk_file="$(cd "$(dirname "$apk_file")" && pwd)/$(basename "$apk_file")" ;;
esac

# GitHub renders "::error::" lines as check-run annotations, and unlike job logs
# those are readable through the API without a token. Anywhere else they would
# just be noise, so they are only emitted under Actions.
annotate() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error::%s\n' "$1"
    else
        printf 'ERROR: %s\n' "$1"
    fi
}

# Ask apk which flags it has instead of guessing. The flags this needs have moved
# between releases, and an unknown flag fails the whole invocation with a usage
# error, which in a log looks just like an install failure.
has_flag() {
    apk add --help 2>&1 | grep -q -- "$1"
}

echo "apk:    $(apk --version 2>&1 | head -1)"
echo "target: $apk_file"
echo "root:   $root"

rm -rf "$work" "$root"
mkdir -p "$work" "$root"

no_scripts=""
if has_flag --scripts; then
    # apk-tools 3 spells it --scripts[=BOOL]; that is what 3.0.8 on the runner
    # documents, and why probing for --no-scripts found nothing and the
    # maintainer script was executed instead.
    no_scripts="--scripts=no"
elif has_flag --no-scripts; then
    no_scripts="--no-scripts"
fi
if [ -n "$no_scripts" ]; then
    echo "note: scripts disabled with $no_scripts (the package's install script is"
    echo "      verified on the device instead; here it would run in a bare root)"
else
    echo "note: this apk cannot disable scripts; the root will be given a shell"
fi

# If scripts cannot be disabled they are executed with the root as their
# filesystem, and a bare root has neither a shell nor the loader a dynamically
# linked one needs: Alpine's BusyBox needs /lib/ld-musl-*.so.1, and without it
# execve fails with ENOENT - apk reports "exited with error 127" *after* writing
# every file, which reads like a defect in the package and is not one.
plant_shell() {
    if [ -x "$root/bin/sh" ] || [ ! -x /bin/busybox ]; then
        return 0
    fi
    mkdir -p "$root/bin" "$root/lib"
    cp /bin/busybox "$root/bin/busybox" 2>/dev/null || true
    ln -sf busybox "$root/bin/sh" 2>/dev/null \
        || cp "$root/bin/busybox" "$root/bin/sh" 2>/dev/null || true
    for ldr in /lib/ld-musl-*.so.1; do
        if [ -e "$ldr" ]; then
            cp "$ldr" "$root/lib/" 2>/dev/null || true
        fi
    done
}

# ---- install -------------------------------------------------------------
# The package declares no dependencies (build-apk passes no `depends` to
# `apk mkpkg`), so a bare root is enough and no repositories are needed.
#
# --root is tried in both positions because apk moved its global options around,
# and the remaining attempts add the flags that relax dependency and repository
# checks, for the case where a future package does carry dependencies. Every
# failure is reported, never swallowed.
installed_with=""
attempts=0
for position in after before; do
    for extra in "$no_scripts" "--scripts=false" "" "--force-broken-world" "--force-non-repository"; do
        attempts=$((attempts + 1))
        rm -rf "$root"
        mkdir -p "$root"
        if [ -z "$no_scripts" ]; then
            plant_shell
        fi
        # shellcheck disable=SC2086  # the flag sets are meant to word-split
        if [ "$position" = after ]; then
            set -- apk add --root "$root" --initdb --allow-untrusted --no-network $no_scripts $extra "$apk_file"
        else
            set -- apk --root "$root" add --initdb --allow-untrusted --no-network $no_scripts $extra "$apk_file"
        fi
        if "$@" > "$work/add.log" 2>&1; then
            installed_with="apk --root $root ($position:${extra:-none})"
            break
        fi
        echo "attempt $attempts failed [$position:${extra:-none}]: $*"
        tail -8 "$work/add.log" | sed 's/^/      /'
        # The error is at the end of apk's output; the beginning only says what
        # it was doing when things went wrong.
        annotate "apk install attempt [$position:${extra:-none}] failed: $(tail -3 "$work/add.log" | tr '\n' '|')"
    done
    if [ -n "$installed_with" ]; then
        break
    fi
done

if [ -z "$installed_with" ]; then
    echo "FAIL: apk could not install $apk_file into $root after $attempts attempt(s)" >&2
    annotate "apk could not install the package after $attempts attempt(s); see the attempts above"
    exit 1
fi
echo "installed with: $installed_with"

# apk's own record of the package - an independent cross-check of the tree.
pkg_name="$(sed -n 's/^Package:[[:space:]]*//p' "$control" 2>/dev/null || true)"
if [ -z "$pkg_name" ]; then
    pkg_name="$(node -p "require('./package.json').name" 2>/dev/null || echo gl-ai-agent)"
fi
echo "--- apk info -L $pkg_name ---"
apk info --root "$root" --no-network -L "$pkg_name" 2>&1 \
    || apk --root "$root" info --no-network -L "$pkg_name" 2>&1 || true

# ---- what actually landed ------------------------------------------------
# apk's own database is not part of the package payload, and neither is the
# BusyBox and musl loader planted above so maintainer scripts could execute. The
# package ships no /bin entries of its own, so filtering those names hides
# nothing.
find "$root" -type f \
    | sed "s#^$root/##" \
    | grep -v '^lib/apk/' \
    | grep -v '^etc/apk/' \
    | grep -v '^bin/busybox$' \
    | grep -v '^bin/sh$' \
    | grep -v '^lib/ld-musl-' \
    | sort > "$work/files.txt" || true

# "mode size path", the form `stat -c '%a %s %n'` prints and the checker's
# --apk-listing reads. stat is called per file because BusyBox find has no
# `-exec ... +`, and paths are assumed to have no spaces.
: > "$work/listing.txt"
while IFS= read -r rel; do
    stat -c "%a %s $rel" "$root/$rel" >> "$work/listing.txt" 2>/dev/null || true
done < "$work/files.txt"

echo "--- files on disk (mode size path) ---"
cat "$work/listing.txt"
echo "files: $(wc -l < "$work/files.txt")"

if [ -n "$listing_out" ]; then
    cp "$work/listing.txt" "$listing_out"
    echo "listing written to $listing_out"
fi

exit 0
