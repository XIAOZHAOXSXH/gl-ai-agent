#!/bin/sh
# Determine the exact eval() contract for SDK4 view bundles by inspecting a
# first-party view (home) shipped by GL.
zcat /www/views/gl-sdk4-ui-home.common.js.gz > /tmp/v.js

echo "=== size ==="; wc -c /tmp/v.js
echo "=== first 260 bytes ==="; cut -c1-260 /tmp/v.js
echo
echo "=== last 260 bytes ==="; tail -c 260 /tmp/v.js
echo
echo "=== does it end with a bare expression? ==="
tail -c 120 /tmp/v.js | grep -o '.\{0,120\}$'

echo
echo "=== how the SPA turns the eval result into a component ==="
zcat /www/js/app.3f5fac80.js.gz > /tmp/a.js
awk 'BEGIN{RS="eval\\(res.data\\)"} NR==2 {print substr($0,1,320)}' /tmp/a.js
echo
echo "--- and how it reads the module export if any ---"
awk 'BEGIN{RS="to.matched"} NR==2 {print substr($0,1,200)}' /tmp/a.js

rm -f /tmp/v.js /tmp/a.js
