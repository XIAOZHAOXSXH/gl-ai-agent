#!/bin/sh
OBJ=${1:-gl_probe5}
cp /usr/lib/oui-httpd/rpc/gl_ai /usr/lib/oui-httpd/rpc/$OBJ
chmod 755 /usr/lib/oui-httpd/rpc/$OBJ

printf '{"jsonrpc":"2.0","method":"call","params":["","%s","rpc",{"m":"selftest","p":{}}],"id":1}' "$OBJ" > /tmp/q.json
echo "===== raw response ====="
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/q.json > /tmp/r.json
wc -c < /tmp/r.json
head -c 900 /tmp/r.json
echo
echo
echo "===== nginx errors since ====="
tail -6 /var/log/nginx/error.log
rm -f /tmp/q.json /tmp/r.json
