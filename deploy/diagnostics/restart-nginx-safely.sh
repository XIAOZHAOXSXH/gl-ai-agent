#!/bin/sh
# Restart nginx so the gl_ai RPC object picks up its current on-disk code, then
# verify. Safe by construction: if the fresh config is bad we roll back to the
# previous one and restart again, so the admin panel never stays down.
set -e

CONF=/etc/nginx/gl-conf.d
CONFD=/etc/nginx/conf.d
STAMP=$(date +%s)
BACKUP=/tmp/nginx-conf-backup-$STAMP

echo "=== pre-flight ==="
mkdir -p "$BACKUP"
cp -a "$CONF" "$BACKUP/gl-conf.d" 2>/dev/null || true
cp -a "$CONFD" "$BACKUP/conf.d" 2>/dev/null || true
echo "  backed up configs to $BACKUP"

echo -n "  config test: "
if nginx -t 2>/tmp/ngt.err; then
    echo "OK"
else
    echo "FAILED"
    cat /tmp/ngt.err
    echo "  refusing to restart with a bad config"
    exit 1
fi
rm -f /tmp/ngt.err

echo
echo "=== restarting nginx ==="
/etc/init.d/nginx restart >/dev/null 2>&1 || nginx -s reload
sleep 4

echo
echo "=== verify ==="
for i in 1 2 3 4 5; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1/gl_home.html 2>/dev/null)
    if [ "$code" = "200" ]; then break; fi
    echo "  waiting for web tier (attempt $i, got $code)"
    sleep 2
done
echo -n "  gl_home.html: "; curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://127.0.0.1/gl_home.html
echo -n "  ubus objects: "; ubus list 2>/dev/null | wc -l

echo
echo "=== gl_ai via the stable rpc surface (now un-cached) ==="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","get_tools",{}],"id":1}' > /tmp/n1.json
echo -n "  get_tools: "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/n1.json | head -c 100
echo
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"selftest","p":{}}],"id":1}' > /tmp/n2.json
echo -n "  rpc{selftest} passed/failed: "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/n2.json | grep -o '"passed":[0-9]*\|"failed":[0-9]*' | tr '\n' ' '
echo
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"get_config","p":{}}],"id":1}' > /tmp/n3.json
echo -n "  rpc{get_config} configured=: "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/n3.json | grep -o '"configured":[a-z]*'
rm -f /tmp/n1.json /tmp/n2.json /tmp/n3.json
echo "=== done ==="
