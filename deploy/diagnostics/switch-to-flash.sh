#!/bin/sh
RPC=http://127.0.0.1/rpc
call() {
    printf '%s' "$1" > /tmp/q.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/q.json
    echo
}

echo "===== 1. switch to deepseek-flash, keep tls off ====="
call '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"set_config","p":{"provider":{"model":"deepseek-flash","verify_tls":false,"protocol":"openai","base_url":"https://api.moleapi.com/v1"}}}],"id":1}' | head -c 260

echo
echo "===== 2. test connection ====="
call '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"test_connection","p":{}}],"id":2}' | head -c 320

echo
echo "===== 3. a real question ====="
call '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{"text":"我的 WiFi 叫什么名字？只回答名字。"}}],"id":3}' > /tmp/s.json
cat /tmp/s.json
TURN=$(sed -n 's/.*"turn_id":"\([^"]*\)".*/\1/p' /tmp/s.json)

OFF=0
i=0
while [ $i -lt 90 ]; do
    i=$((i + 1))
    printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"poll","p":{"turn_id":"%s","offset":%s}}],"id":4}' "$TURN" "$OFF" > /tmp/p.json
    R=$(curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/p.json)
    OFF=$(printf '%s' "$R" | sed -n 's/.*"offset":\([0-9]*\).*/\1/p')
    printf '%s' "$R" | grep -q '"finished":true' && { echo "$R" | head -c 900; echo; break; }
    sleep 1
done
echo "  polls=$i"
echo
echo "===== 4. event log ====="
tail -8 /tmp/gl-ai-agent/turns/$TURN.jsonl 2>/dev/null | cut -c1-220
rm -f /tmp/q.json /tmp/s.json /tmp/p.json
