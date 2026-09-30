#!/bin/sh
RPC=http://127.0.0.1/rpc
q() {
    printf '%s' "$1" > /tmp/cq.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/cq.json
    echo
}

echo "===== A. get_config (known good) ====="
q '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"get_config","p":{}}],"id":1}' | head -c 200

echo
echo "===== B. chat as the UI sends it (with text) ====="
q '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{"text":"hello"}}],"id":3}'

echo
echo "===== C. chat with empty params ====="
q '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{}}],"id":4}'

echo
echo "===== D. selftest (known good, empty params) ====="
q '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"selftest","p":{}}],"id":5}' | head -c 120

echo
echo "===== E. does the validator know 'chat'? ====="
grep -c "chat = true" /usr/share/gl-validator.d/gl_ai.lua

echo
echo "===== F. is chat exported by the backend? ====="
lua -e '
local t = dofile("/usr/lib/oui-httpd/rpc/gl_ai")
print("  entry has rpc:    " .. tostring(t.rpc ~= nil))
local m = dofile("/usr/lib/lua/glai/rpc_entry.lua")
print("  backend has chat: " .. tostring(m.chat ~= nil))
print("  backend methods:  " .. (function() local n=0 for k,v in pairs(m) do if type(v)=="function" then n=n+1 end end return n end)())
'

echo
echo "===== G. nginx log for the rejected call ====="
tail -4 /var/log/nginx/error.log

rm -f /tmp/cq.json
