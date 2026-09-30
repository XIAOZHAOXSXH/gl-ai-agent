#!/bin/sh
echo "===== nginx errors (recent) ====="
tail -25 /var/log/nginx/error.log | grep -v "open()" | tail -15

echo
echo "===== can the tool layer list clients right now? ====="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"selftest","p":{}}],"id":1}' > /tmp/q.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/q.json > /tmp/s.json
grep -o '"passed":[0-9]*\|"failed":[0-9]*' /tmp/s.json
echo "--- per tool ---"
sed 's/},{/}\n{/g' /tmp/s.json | grep -o '"name":"[a-z_]*","ok":[a-z]*,"ms":[0-9]*' | sed 's/"name":"/  /;s/","ok":/  ok=/;s/,"ms":/  ms=/'
echo "--- failures ---"
sed 's/},{/}\n{/g' /tmp/s.json | grep -o '"error":"[^"]*"' | head -5

echo
echo "===== direct list_clients timing ====="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","clients","get_list",{}],"id":1}' > /tmp/cl.json
S=$(date +%s%N 2>/dev/null || date +%s)
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/cl.json | wc -c
E=$(date +%s%N 2>/dev/null || date +%s)
echo "  raw clients.get_list done"

echo
echo "===== turn files still around ====="
ls -la /tmp/gl-ai-agent/turns/ 2>/dev/null | tail -4

rm -f /tmp/q.json /tmp/s.json /tmp/cl.json
