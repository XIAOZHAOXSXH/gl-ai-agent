#!/bin/sh
# Trigger one agent turn and dump the exact request body the LLM client sent.
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{"text":"hi"}}],"id":9}' > /tmp/c.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/c.json
echo
sleep 10
echo
echo "===== request body the client sent ====="
grep "gl_ai llm" /var/log/nginx/error.log | tail -1 | sed 's/.*body=//' | head -c 2000
echo
echo
echo "===== length ====="
grep "gl_ai llm" /var/log/nginx/error.log | tail -1 | wc -c
rm -f /tmp/c.json
