#!/bin/sh
# Configure the real provider on the device and run a live end-to-end turn.
RPC=http://127.0.0.1/rpc
call() {
    printf '%s' "$2" > /tmp/lq.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/lq.json
    echo
}

echo "===== 1. save provider config ====="
call set_config '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"set_config","p":{"provider":{"protocol":"openai","base_url":"https://api.moleapi.com/v1","model":"gpt-5.6-luna","api_key":"sk-vACd7jPqzXIQohymNxsJbJJc9LEVZ0Fz7LgPJCuu7huSlkck","verify_tls":false},"agent":{"permission":"readonly"}}}],"id":1}' | head -c 240

echo
echo "===== 2. test connection (real HTTPS call) ====="
call test_connection '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"test_connection","p":{}}],"id":2}' | head -c 300

echo
echo "===== 3. live agent turn ====="
call chat '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{"text":"What is my WiFi name and how many devices are online? Answer in one short sentence."}}],"id":3}' > /tmp/lstart.json
cat /tmp/lstart.json
TURN=$(sed -n 's/.*"turn_id":"\([^"]*\)".*/\1/p' /tmp/lstart.json)
echo "  turn=$TURN"

echo
echo "===== 4. poll until finished ====="
OFF=0
i=0
# reasoning models answer slowly (reasoning_tokens per step), so allow a
# generous window before giving up on the poll loop
while [ $i -lt 150 ]; do
    i=$((i + 1))
    printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"poll","p":{"turn_id":"%s","offset":%s}}],"id":4}' "$TURN" "$OFF" > /tmp/lp.json
    RESP=$(curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/lp.json)
    OFF=$(printf '%s' "$RESP" | sed -n 's/.*"offset":\([0-9]*\).*/\1/p')
    printf '%s' "$RESP" | grep -q '"finished":true' && { echo "$RESP" | head -c 1500; echo; break; }
    sleep 2
done
echo "  polls=$i"

echo
echo "===== 5. event log ====="
tail -12 /tmp/gl-ai-agent/turns/$TURN.jsonl 2>/dev/null | cut -c1-200

rm -f /tmp/lq.json /tmp/lstart.json /tmp/lp.json
