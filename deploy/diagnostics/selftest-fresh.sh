#!/bin/sh
# Selftest through a fresh object name (bypasses the stale gl_ai worker cache).
OBJ=${1:-gl_probe3}
cp /usr/lib/oui-httpd/rpc/gl_ai /usr/lib/oui-httpd/rpc/$OBJ
chmod 755 /usr/lib/oui-httpd/rpc/$OBJ

printf '{"jsonrpc":"2.0","method":"call","params":["","%s","rpc",{"m":"selftest","p":{}}],"id":1}' "$OBJ" > /tmp/st_q.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/st_q.json > /tmp/st_r.json

echo "===== summary ====="
grep -o '"passed":[0-9]*' /tmp/st_r.json
grep -o '"failed":[0-9]*' /tmp/st_r.json
grep -o '"total":[0-9]*' /tmp/st_r.json
grep -o '"configured":[a-z]*' /tmp/st_r.json

echo
echo "===== per tool ====="
sed 's/},{/}\n{/g' /tmp/st_r.json | grep -o '"name":"[a-z_]*","ok":[a-z]*,"ms":[0-9]*,"bytes":[0-9]*' \
  | sed 's/"name":"/  /; s/","ok":/  ok=/; s/,"ms":/  ms=/; s/,"bytes":/  bytes=/'

echo
echo "===== failures ====="
sed 's/},{/}\n{/g' /tmp/st_r.json | grep '"ok":false' | head -8 | sed 's/^/  /'

rm -f /tmp/st_q.json /tmp/st_r.json
