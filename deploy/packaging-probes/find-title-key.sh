#!/bin/sh
# Find the exact view -> menu title key transformation.
zcat /www/js/app.3f5fac80.js.gz > /tmp/a.js

echo "=== searching for title key construction ==="
for pat in 'menu_"' '"menu_' 'menu_${' '`menu_' 'menu_"+' '+view' 'titleKey' 'getMenuTitle'; do
    n=$(grep -c -- "$pat" /tmp/a.js 2>/dev/null || echo 0)
    echo "  pattern [$pat] occurrences=$n"
done
echo
echo "=== context around menu_ literal concatenation ==="
awk 'BEGIN{RS="menu_"} NR<=40 {c=substr($0,1,60); if (c ~ /^[a-z_$]/ || c ~ /^"/) print "  [" NR "] " c}' /tmp/a.js | head -20
echo
echo "=== i18n request path in the SPA ==="
awk 'BEGIN{RS="i18n"} NR>1 {print "  " substr($0,1,130); if (NR>4) exit}' /tmp/a.js
echo
echo "=== how \$t is wired (look for vue-i18n init) ==="
awk 'BEGIN{RS="locale"} NR>1 {print "  " substr($0,1,110); if (NR>6) exit}' /tmp/a.js

rm -f /tmp/a.js
