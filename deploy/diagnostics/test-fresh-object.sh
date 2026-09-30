#!/bin/sh
# Decisive test: an identical entry under a fresh object name has no cache.
cp /usr/lib/oui-httpd/rpc/gl_ai /usr/lib/oui-httpd/rpc/gl_probe2
chmod 755 /usr/lib/oui-httpd/rpc/gl_probe2

echo "=== same file, new object name: does 'rpc' dispatch work? ==="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_probe2","rpc",{"m":"get_tools","p":{}}],"id":1}' > /tmp/p2.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/p2.json | head -c 200
echo
echo -n "  tool names found: "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/p2.json | grep -o '"name"' | wc -l

echo
echo "=== and selftest through it ==="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_probe2","rpc",{"m":"selftest","p":{}}],"id":1}' > /tmp/p3.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/p3.json > /tmp/p3r.json
echo -n "  passed: "; grep -o '"passed":[0-9]*' /tmp/p3r.json
echo -n "  failed: "; grep -o '"failed":[0-9]*' /tmp/p3r.json
echo "  --- per tool ---"
sed 's/},{/}\n{/g' /tmp/p3r.json | grep -o '"name":"[a-z_]*","ok":[a-z]*' | sed 's/"name":"/    /; s/","ok":/  ok=/'
echo "  --- failures ---"
sed 's/},{/}\n{/g' /tmp/p3r.json | grep '"ok":false' | sed 's/^/    /' | head -8

rm -f /tmp/p2.json /tmp/p3.json /tmp/p3r.json
