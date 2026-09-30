#!/bin/sh
# BusyBox grep lacks {n,m} regex bounds: extract fixed-width context instead.
zcat /www/js/app.3f5fac80.js.gz > /tmp/a.js

echo "=== context around eval(res.data) ==="
grep -o '.\{0,600\}eval(res\.data.\{0,600\}' /tmp/a.js 2>/dev/null || \
    awk 'BEGIN{RS="eval(res.data)"} NR<=3 {print substr($0, length($0)-600) "\n-----"}' /tmp/a.js

echo
echo "=== rough: 900 chars before eval(res.data) ==="
awk 'BEGIN{RS="eval(res.data)"} NR==2 {print substr($0, length($0)-900)}' /tmp/a.js
echo
echo "=== 500 chars after eval(res.data) ==="
awk 'BEGIN{RS="eval(res.data)"} NR==2 {print substr($0,1,500)}' /tmp/a.js
echo
echo "=== all eval occurrences ==="
awk 'BEGIN{RS="eval\\("} NR>1 {print "--- " substr($0,1,120)}' /tmp/a.js | head -20

rm -f /tmp/a.js
