#!/bin/sh
# Find how the SDK derives a menu entry's display title, and dump the live
# menu list so the gl-ai entry can be inspected exactly.
zcat /www/js/app.3f5fac80.js.gz > /tmp/a.js

echo "=== menu title helper ==="
awk 'BEGIN{RS="menu_title"} NR>1 {print "--- " substr($0,1,150); if (NR>6) exit}' /tmp/a.js
echo
echo "=== i18n key construction (menu_ + view) ==="
awk 'BEGIN{RS="menu_"} NR>1 {print "--- " substr($0,1,110); if (NR>10) exit}' /tmp/a.js
echo
echo "=== i18n file loading ==="
awk 'BEGIN{RS="gl-sdk4-ui-"} NR>1 {print "--- " substr($0,1,120); if (NR>8) exit}' /tmp/a.js

rm -f /tmp/a.js

echo
echo "=== live menu list: gl-ai entry ==="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","ui","get_menu_list",{}],"id":1}' > /tmp/mp.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/mp.json > /tmp/ml.json
wc -c /tmp/ml.json
sed 's/},{/}\n{/g' /tmp/ml.json | grep -i 'gl-ai'
echo "--- total entries ---"
sed 's/},{/}\n{/g' /tmp/ml.json | grep -c '"view"'
echo "--- first entry for shape reference ---"
sed 's/},{/}\n{/g' /tmp/ml.json | sed -n '2p' | cut -c1-400
rm -f /tmp/mp.json /tmp/ml.json
