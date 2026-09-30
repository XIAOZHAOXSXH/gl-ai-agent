#!/bin/sh
# Temporarily raise nginx log level so a dying timer coroutine leaves a trace.
cp /etc/nginx/nginx.conf /tmp/nginx.conf.bak

sed -i 's#error_log /var/log/nginx/error.log notice;#error_log /var/log/nginx/error.log debug;#' /etc/nginx/nginx.conf
grep -n "error_log" /etc/nginx/nginx.conf

if nginx -t 2>/dev/null; then
    nginx -s reload
    echo "reloaded with debug logging"
else
    echo "config test failed; restoring"
    cp /tmp/nginx.conf.bak /etc/nginx/nginx.conf
    exit 1
fi

sleep 2

echo
echo "===== run one turn ====="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{"text":"How many devices are online right now?"}}],"id":1}' > /tmp/c.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/c.json
echo "  (waiting 100s)"
sleep 100

echo
echo "===== timer / coroutine diagnostics ====="
grep -iE "lua (timer|coroutine)|coroutine|resume|failed to run|lua entry thread|timer lua" /var/log/nginx/error.log | tail -12

echo
echo "===== last gl_ai related lines ====="
grep -i "gl_ai\|glai" /var/log/nginx/error.log | grep -v "rpc.lua:263" | tail -10

echo
echo "===== restore log level ====="
cp /tmp/nginx.conf.bak /etc/nginx/nginx.conf
nginx -t >/dev/null 2>&1 && nginx -s reload && echo "restored"
rm -f /tmp/c.json /tmp/nginx.conf.bak
