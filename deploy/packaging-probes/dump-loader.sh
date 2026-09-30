#!/bin/sh
# Dump the complete SDK4 view loader so the eval contract is unambiguous.
zcat /www/js/app.3f5fac80.js.gz > /tmp/a.js

echo "=== 1400 chars before eval(res.data) ==="
awk 'BEGIN{RS="eval\\(res\\.data\\)"} NR==2 {n=length($0); print substr($0, n-1400)}' /tmp/a.js

echo
echo "=== 400 chars after eval(res.data) ==="
awk 'BEGIN{RS="eval\\(res\\.data\\)"} NR==2 {print substr($0, 1, 400)}' /tmp/a.js

echo
echo "=== is there a global module shim anywhere in the app? ==="
grep -c 'window.module' /tmp/a.js
grep -o 'window\.module.\{0,60\}' /tmp/a.js | head -5
echo "--- 'var module' / 'module={exports' patterns ---"
grep -o 'module\s*=\s*{\s*exports.\{0,40\}' /tmp/a.js | head -5

echo
echo "=== the whole component-loading function, if findable ==="
awk 'BEGIN{RS="loadViewBeforeEnter"} NR==2 {print substr($0,1,700)}' /tmp/a.js

rm -f /tmp/a.js
