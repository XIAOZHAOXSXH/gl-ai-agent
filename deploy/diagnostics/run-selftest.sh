#!/bin/sh
# Run the in-nginx tool selftest and print a readable report.
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","selftest",{}],"id":1}' > /tmp/st_q.json

echo "===== raw head ====="
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/st_q.json | head -c 300
echo

echo
echo "===== per-tool ====="
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/st_q.json > /tmp/st_r.json
sed 's/},{/}\n{/g' /tmp/st_r.json | grep -o '"name":"[a-z_]*","ok":[a-z]*' | sed 's/"name":"/  /; s/","ok":/   ok=/'

echo
echo "===== failures ====="
sed 's/},{/}\n{/g' /tmp/st_r.json | grep '"ok":false' | head -8

echo
echo "===== counters ====="
grep -o '"passed":[0-9]*' /tmp/st_r.json
grep -o '"failed":[0-9]*' /tmp/st_r.json
grep -o '"total":[0-9]*' /tmp/st_r.json
grep -o '"configured":[a-z]*' /tmp/st_r.json

rm -f /tmp/st_q.json /tmp/st_r.json
