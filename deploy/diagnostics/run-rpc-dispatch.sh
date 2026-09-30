#!/bin/sh
RPC=http://127.0.0.1/rpc
q() {
    printf '%s' "$1" > /tmp/gq.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/gq.json
}

echo "===== A. generic rpc dispatch (the stable surface) ====="
echo -n "  rpc{get_config}: "
q '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"get_config","p":{}}],"id":1}' | head -c 220
echo
echo -n "  rpc{get_tools} count: "
q '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"get_tools","p":{}}],"id":1}' | grep -o '"name"' | wc -l
echo -n "  rpc{unknown}: "
q '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"nope","p":{}}],"id":1}' | head -c 120
echo

echo
echo "===== B. selftest via dispatch (new code, no nginx restart) ====="
q '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"selftest","p":{}}],"id":1}' > /tmp/gs.json
grep -o '"ok":true' /tmp/gs.json | head -1
echo -n "  passed: "; grep -o '"passed":[0-9]*' /tmp/gs.json
echo -n "  failed: "; grep -o '"failed":[0-9]*' /tmp/gs.json
echo -n "  total:  "; grep -o '"total":[0-9]*' /tmp/gs.json
echo "  --- per tool ---"
sed 's/},{/}\n{/g' /tmp/gs.json | grep -o '"name":"[a-z_]*","ok":[a-z]*,"ms":[0-9]*' | sed 's/"name":"/    /; s/","ok":/  ok=/; s/,"ms":/  ms=/'
echo "  --- failures ---"
sed 's/},{/}\n{/g' /tmp/gs.json | grep '"ok":false' | sed 's/^/    /' | head -8
rm -f /tmp/gq.json /tmp/gs.json
