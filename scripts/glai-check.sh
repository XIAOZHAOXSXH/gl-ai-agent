#!/bin/sh
# Read-only on-device validation of the GL-AI backend.
# Never restarts nginx and never touches a system service.
#   sh /tmp/glai-check.sh
RPC=http://127.0.0.1/rpc
call() {
    printf '%s' "$2" > /tmp/gc_q.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/gc_q.json
}

echo "===== 1. lua syntax ====="
FAIL=0
for f in /usr/lib/lua/glai/agent.lua \
         /usr/lib/lua/glai/config.lua \
         /usr/lib/lua/glai/events.lua \
         /usr/lib/lua/glai/llm.lua \
         /usr/lib/lua/glai/redact.lua \
         /usr/lib/lua/glai/rpc.lua \
         /usr/lib/lua/glai/rpc_entry.lua \
         /usr/lib/lua/glai/session.lua \
         /usr/lib/lua/glai/tools.lua \
         /usr/lib/lua/glai/turns.lua \
         /usr/lib/oui-httpd/rpc/gl_ai \
         /usr/share/gl-validator.d/gl_ai.lua; do
    if lua -e "assert(loadfile('$f'))" 2>/tmp/gc_err; then
        echo "  OK    $f"
    else
        echo "  FAIL  $f"
        cat /tmp/gc_err
        FAIL=1
    fi
done
rm -f /tmp/gc_err

echo
echo "===== 2. module registry ====="
lua -e '
local ok, t = pcall(require, "glai.tools")
if not ok then print("  glai.tools: FAIL " .. tostring(t)); os.exit(1) end
local n = 0
for _ in ipairs(t.registry) do n = n + 1 end
print("  tools:    " .. n)
local ok2, s = pcall(t.schemas)
print("  schemas:  " .. (ok2 and #s or ("FAIL " .. tostring(s))))
-- JSON Schema forbids an empty "required"; gateways reject it with HTTP 400
local bad = 0
if ok2 then
  for _, sc in ipairs(s) do
    local p = sc["function"].parameters
    if p.required ~= nil then
      local empty = true
      for _ in pairs(p.required) do empty = false break end
      if empty then bad = bad + 1 end
    end
  end
end
print("  schemas with empty required: " .. bad .. (bad == 0 and " (good)" or " (WILL BE REJECTED)"))
'

echo
echo "===== 3. RPC surface ====="
echo -n "  get_config: "
call get_config '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"get_config","p":{}}],"id":1}' | head -c 240
echo
echo -n "  get_tools count: "
call get_tools '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"get_tools","p":{}}],"id":2}' | grep -o '"name"' | wc -l
echo -n "  pending_approvals: "
call pa '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"pending_approvals","p":{}}],"id":3}' | head -c 90

echo
echo "===== 4. live tool selftest (must run inside nginx) ====="
call st '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"selftest","p":{}}],"id":4}' > /tmp/gc_st.json
grep -o '"passed":[0-9]*' /tmp/gc_st.json
grep -o '"failed":[0-9]*' /tmp/gc_st.json
echo -n "  schema problems: "
call sp '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"selftest","p":{}}],"id":5}' | grep -o '"schema_problems":\[[^]]*\]' | head -c 200
echo
echo "  --- per tool ---"
sed 's/},{/}\n{/g' /tmp/gc_st.json | grep -o '"name":"[a-z_]*","ok":[a-z]*,"ms":[0-9]*' | sed 's/"name":"/    /; s/","ok":/  ok=/; s/,"ms":/  ms=/'
echo "  --- failures ---"
sed 's/},{/}\n{/g' /tmp/gc_st.json | grep -o '"error":"[^"]*"' | head -5 | sed 's/^/    /'

echo
echo "===== 5. nginx untouched by us ====="
echo -n "  our nginx conf files: "
ls /etc/nginx/gl-conf.d/gl-ai-agent.conf /etc/nginx/conf.d/gl-ai-agent-main.conf 2>/dev/null | wc -l
echo -n "  nginx config valid: "
nginx -t 2>&1 | tail -1
echo -n "  ubus objects: "
ubus list 2>/dev/null | wc -l

rm -f /tmp/gc_q.json /tmp/gc_st.json
echo "===== end ====="
exit $FAIL
