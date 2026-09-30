#!/bin/sh
RPC=http://127.0.0.1/rpc
call() {
    printf '%s' "$1" > /tmp/q.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/q.json
    echo
}
turn() {
    call "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"gl_ai\",\"rpc\",{\"m\":\"chat\",\"p\":{\"text\":\"$1\"}}],\"id\":3}" > /tmp/s.json
    T=$(sed -n 's/.*"turn_id":"\([^"]*\)".*/\1/p' /tmp/s.json)
    OFF=0; i=0
    while [ $i -lt 90 ]; do
        i=$((i + 1))
        printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"poll","p":{"turn_id":"%s","offset":%s}}],"id":4}' "$T" "$OFF" > /tmp/p.json
        R=$(curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/p.json)
        OFF=$(printf '%s' "$R" | sed -n 's/.*"offset":\([0-9]*\).*/\1/p')
        printf '%s' "$R" | grep -q '"finished":true' && break
        sleep 1
    done
    echo "  polls=$i"
}

echo "===== current permission mode ====="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"get_config","p":{}}],"id":1}' > /tmp/c.json
curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/c.json | grep -o '"permission":"[a-z]*"'

echo
echo "===== force ask mode, then request a write ====="
call '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"set_config","p":{"agent":{"permission":"ask"}}}],"id":2}' | grep -o '"permission":"[a-z]*"'
turn "把访客网络的 SSID 改成 Guest-Test"

echo
echo "===== event log of the newest turn ====="
NEWEST=$(ls -1t /tmp/gl-ai-agent/turns/*.jsonl 2>/dev/null | head -1)
echo "  $NEWEST"
cat "$NEWEST" 2>/dev/null | cut -c1-260

echo
echo "===== pending approvals file ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null || echo "  (none)"
echo
rm -f /tmp/q.json /tmp/s.json /tmp/p.json /tmp/c.json
