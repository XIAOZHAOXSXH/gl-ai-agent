#!/bin/sh
# 1) confirm the model name works, 2) check what the device has persisted.
KEY='sk-vACd7jPqzXIQohymNxsJbJJc9LEVZ0Fz7LgPJCuu7huSlkck'
BASE='https://api.moleapi.com/v1'

echo "===== model availability ====="
for M in deepseek-flash deepseek-chat gpt-5.6-luna; do
    printf '%s' "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":16}" > /tmp/m.json
    code=$(curl -s -o /tmp/mr.json -w '%{http_code}' --max-time 45 -X POST "$BASE/chat/completions" \
        -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' --data-binary @/tmp/m.json)
    echo -n "  $M -> HTTP $code  "
    head -c 130 /tmp/mr.json
    echo
done

echo
echo "===== what the device has persisted ====="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"get_config","p":{}}],"id":1}' > /tmp/c.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/c.json
echo
echo "--- raw config.json (key masked) ---"
sed 's/"api_key":"[^"]*"/"api_key":"***"/' /etc/gl-ai-agent/config.json 2>/dev/null
echo
rm -f /tmp/m.json /tmp/mr.json /tmp/c.json
