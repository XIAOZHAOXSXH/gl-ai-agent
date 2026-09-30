#!/bin/sh
RPC=http://127.0.0.1/rpc
call() {
    printf '%s' "$1" > /tmp/q.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/q.json
    echo
}

echo "===== left-over turn state (in_flight shows a step is parked) ====="
for f in $(ls -1t /tmp/gl-ai-agent/state/*.json 2>/dev/null | head -3); do
    echo "  $f"
    sed 's/,"messages":.*//' "$f" | cut -c1-260
    echo
done

echo "===== approvals file ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null || echo "  (absent)"
echo

echo "===== does approve actually work end to end? ====="
# park a fake pending approval, then decide it, and confirm it moved
printf '%s' '{"probe-1":"pending"}' > /tmp/gl-ai-agent/approvals.json
call '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"approve","p":{"id":"probe-1","allow":true}}],"id":1}'
echo -n "  approvals now: "; cat /tmp/gl-ai-agent/approvals.json; echo
printf '%s' '{"probe-2":"pending"}' > /tmp/gl-ai-agent/approvals.json
call '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"approve","p":{"id":"probe-2","allow":false}}],"id":2}'
echo -n "  approvals now: "; cat /tmp/gl-ai-agent/approvals.json; echo
rm -f /tmp/gl-ai-agent/approvals.json

echo
echo "===== nginx: any timeout on our requests? ====="
grep -nE "client_body_timeout|send_timeout|keepalive_timeout|proxy_read_timeout|fastcgi_read_timeout" /etc/nginx/conf.d/gl.conf
rm -f /tmp/q.json
