#!/bin/sh
# Continue the parked turn from smoke-turn.sh: read the approval id straight from
# the approvals file (no fragile regex), decline it, and watch the turn finish.
RPC=http://127.0.0.1/rpc
call() {
    printf '%s' "$1" > /tmp/cq.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/cq.json
}

TURN=$(ls -1t /tmp/gl-ai-agent/state/*.json 2>/dev/null | head -1 | sed 's#.*/##; s#\.json$##')
echo "  turn=$TURN"

echo "===== approvals before ====="
cat /tmp/gl-ai-agent/approvals.json; echo

# pull every pending id out of the approvals JSON with sed alone
IDS=$(sed 's/","/\n/g; s/[{}"]//g' /tmp/gl-ai-agent/approvals.json | sed -n 's/:pending$//p')
echo "  pending ids: $IDS"

for id in $IDS; do
    printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"approve","p":{"id":"%s","allow":false}}],"id":9}' "$id" > /tmp/a.json
    echo -n "  decline $id -> "; call "$(cat /tmp/a.json)"; echo
done

echo
echo "===== approvals after ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null; echo
echo -n "  awaiting marker: "; ls -1 /tmp/gl-ai-agent/awaiting/ 2>/dev/null | tr '\n' ' '; echo

echo
echo "===== keep polling ====="
OFF=$(wc -c < /tmp/gl-ai-agent/turns/$TURN.jsonl 2>/dev/null || echo 0)
i=0
while [ $i -lt 90 ]; do
    i=$((i + 1))
    printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"poll","p":{"turn_id":"%s","offset":%s}}],"id":2}' "$TURN" "$OFF" > /tmp/p.json
    R=$(call "$(cat /tmp/p.json)")
    OFF=$(printf '%s' "$R" | sed -n 's/.*"offset":\([0-9]*\).*/\1/p')
    if printf '%s' "$R" | grep -q '"finished":true'; then
        echo "  [$i] FINISHED"
        printf '%s' "$R" | head -c 600; echo
        break
    fi
    FIN=$(printf '%s' "$R" | grep -o '"finished":[a-z]*' | head -1)
    [ $((i % 15)) -eq 0 ] && echo "  [$i] $FIN"
    sleep 1
done
echo "  polls=$i"

echo
echo "===== final event log ====="
tail -8 /tmp/gl-ai-agent/turns/$TURN.jsonl 2>/dev/null | cut -c1-190

echo
echo "===== router unchanged? ====="
echo -n "  2.4G main SSID: "; uci get wireless.default_radio0.ssid
if uci show wireless | grep -q "GL-Smoke-2G"; then echo "  LEAKED"; else echo "  clean"; fi

rm -f /tmp/cq.json /tmp/a.json /tmp/p.json
