#!/bin/sh
# Focused bisect: is the inner tar fine and the ar layer the problem?
PKG=/tmp/gl-ai-agent_0.1.0_all.ipk
W=/tmp/ipkdbg
rm -rf $W; mkdir -p $W/u
cd $W

echo "=== opkg verdict ==="
opkg install --force-reinstall $PKG 2>&1 | tail -2

echo
echo "=== extract inner members with dd (no ar needed) ==="
# parse ar by hand: 8 global + 60 header + data (even padded)
off=8
i=0
while [ $i -lt 3 ]; do
    name=$(dd if=$PKG bs=1 skip=$((off)) count=16 2>/dev/null | tr -d '\0' | tr -d ' ')
    size=$(dd if=$PKG bs=1 skip=$((off+48)) count=10 2>/dev/null | tr -d ' \0')
    echo "  member[$i] name=$name size=$size"
    case "$name" in
        *control.tar.gz*) dd if=$PKG of=u/control.tar.gz bs=1 skip=$((off+60)) count=$size 2>/dev/null ;;
        *data.tar.gz*)    dd if=$PKG of=u/data.tar.gz    bs=1 skip=$((off+60)) count=$size 2>/dev/null ;;
        *debian-binary*)  dd if=$PKG of=u/debian-binary bs=1 skip=$((off+60)) count=$size 2>/dev/null ;;
    esac
    step=$((60 + size))
    [ $((size % 2)) -ne 0 ] && step=$((step + 1))
    off=$((off + step))
    i=$((i + 1))
done
ls -la u/

echo
echo "=== can BusyBox tar read our inner tarballs? ==="
cd u
gunzip -c data.tar.gz > data.tar 2>/dev/null && echo "  gunzip data: OK $(wc -c < data.tar) bytes" || echo "  gunzip data: FAIL"
gunzip -c control.tar.gz > control.tar 2>/dev/null && echo "  gunzip control: OK $(wc -c < control.tar) bytes" || echo "  gunzip control: FAIL"
echo "  --- tar -tvf data.tar ---"
tar -tvf data.tar 2>&1 | head -5
echo "  --- tar -tvf control.tar ---"
tar -tvf control.tar 2>&1 | head -6
echo "  --- debian-binary ---"
cat debian-binary; echo

echo
echo "=== repack with the router's own tar and retry install ==="
mkdir -p d2 c2
tar xf data.tar -C d2 2>/dev/null && echo "  extracted data OK ($(find d2 -type f | wc -l) files)"
tar xf control.tar -C c2 2>/dev/null && echo "  extracted control OK"
tar -czf data2.tar.gz -C d2 . 2>/dev/null && echo "  re-tar data OK"
tar -czf control2.tar.gz -C c2 . 2>/dev/null && echo "  re-tar control OK"

printf '2.0\n' > debian-binary
# build ar manually with printf (BusyBox has no ar)
mk_ar() {
    printf '!<arch>\n'
    for f in "$@"; do
        n=$(printf '%-16s' "$f/")
        s=$(wc -c < "$f")
        printf '%s' "$n"
        printf '%-12s' "0"
        printf '%-6s' "0"
        printf '%-6s' "0"
        printf '%-10s' "$s"
        printf '`\n'
        cat "$f"
        [ $((s % 2)) -ne 0 ] && printf '\n'
    done
}
mk_ar debian-binary control2.tar.gz data2.tar.gz > repack.ipk
echo "  repack.ipk: $(wc -c < repack.ipk) bytes"
opkg install --force-reinstall ./repack.ipk 2>&1 | tail -3

cd /; rm -rf $W
echo "===== END ====="
