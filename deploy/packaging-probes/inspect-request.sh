#!/bin/sh
# Trigger a turn, then show which tool schema the gateway is unhappy with.
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{"text":"hi"}}],"id":9}' > /tmp/c.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/c.json >/dev/null
sleep 10

echo "===== request size ====="
wc -c /tmp/gl-ai-agent/last-request.json 2>/dev/null

echo
echo "===== tools array (pretty split) ====="
sed 's/"type":"function"/\n"type":"function"/g' /tmp/gl-ai-agent/last-request.json 2>/dev/null | tail -n +2 | head -3

echo
echo "===== first tool schema in full ====="
lua -e '
local cjson = require "cjson"
local f = io.open("/tmp/gl-ai-agent/last-request.json", "r")
if not f then print("  no request captured"); os.exit(0) end
local ok, body = pcall(cjson.decode, f:read("*a")); f:close()
if not ok then print("  body is not valid JSON"); os.exit(0) end
print("  keys: " .. (function() local t={} for k in pairs(body) do t[#t+1]=k end table.sort(t) return table.concat(t,", ") end)())
print("  model: " .. tostring(body.model) .. "  temperature: " .. tostring(body.temperature)
    .. "  max_tokens: " .. tostring(body.max_tokens) .. "  stream: " .. tostring(body.stream))
print("  tools: " .. tostring(body.tools and #body.tools or 0))
if body.tools and body.tools[1] then
    print("  tool[1]: " .. cjson.encode(body.tools[1]):sub(1, 600))
end
print("  messages: " .. tostring(body.messages and #body.messages or 0))
'
rm -f /tmp/c.json
