#!/bin/sh
# Exercise the new turn pipeline: chat -> poll.
# With no provider configured the turn must fail fast and cleanly, and the
# event log must still terminate so the UI stops polling.
RPC=http://127.0.0.1/rpc
call() {
    printf '%s' "$2" > /tmp/gq.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/gq.json
    echo
}

echo "===== 1. syntax of the new modules ====="
for f in /usr/lib/lua/glai/events.lua /usr/lib/lua/glai/turns.lua; do
    if lua -e "assert(loadfile('$f'))" 2>/tmp/e; then echo "  OK   $f"; else echo "  FAIL $f"; cat /tmp/e; fi
done
rm -f /tmp/e

echo
echo "===== 2. module load (outside nginx, pure-lua parts) ====="
lua -e '
local ok, ev = pcall(require, "glai.events")
print("  glai.events: " .. (ok and "OK" or tostring(ev)))
if ok then
    local id = ev.new_id()
    ev.create(id)
    ev.append(id, { type = "text", text = "hello" })
    ev.append(id, { type = "done" })
    local list, off, fin = ev.read(id, 0)
    print("  roundtrip: events=" .. #list .. " offset=" .. off .. " finished=" .. tostring(fin))
    ev.remove(id)
end
'

echo
echo "===== 3. start a turn (no provider configured) ====="
call chat '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{"text":"hello router"}}],"id":1}' > /tmp/start.json
cat /tmp/start.json
TURN=$(sed -n 's/.*"turn_id":"\([^"]*\)".*/\1/p' /tmp/start.json)
echo "  turn_id=$TURN"

echo
echo "===== 4. poll it ====="
if [ -n "$TURN" ]; then
    sleep 2
    printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"poll","p":{"turn_id":"%s","offset":0}}],"id":1}' "$TURN" > /tmp/poll.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/poll.json | head -c 700
    echo
    echo "  --- raw event log ---"
    cat /tmp/gl-ai-agent/turns/$TURN.jsonl 2>/dev/null | head -5
    echo "  --- turn files present ---"
    ls /tmp/gl-ai-agent/turns/ 2>/dev/null | tail -3
fi

echo
echo "===== 5. approval file plumbing ====="
printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"pending_approvals","p":{}}],"id":1}' > /tmp/pa.json
echo -n "  pending_approvals: "
curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/pa.json | head -c 160
echo

rm -f /tmp/gq.json /tmp/start.json /tmp/poll.json /tmp/pa.json
echo "===== done ====="
