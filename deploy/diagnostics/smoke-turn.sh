#!/bin/sh
# Drive a full turn including a declined confirmation, purely over RPC, and watch
# for the terminal event. This isolates the turn state machine from the browser.
RPC=http://127.0.0.1/rpc
call() {
    printf '%s' "$1" > /tmp/tq.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/tq.json
}

echo "===== start ====="
call '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"chat","p":{"text":"把 2.4G 主网络的 SSID 改成 GL-Smoke-2G，其他别动"}}],"id":1}' > /tmp/ts.json
cat /tmp/ts.json
TURN=$(sed -n 's/.*"turn_id":"\([^"]*\)".*/\1/p' /tmp/ts.json)
echo "  turn=$TURN"

OFF=0
CONFIRMED=""
i=0
while [ $i -lt 120 ]; do
    i=$((i + 1))
    printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"poll","p":{"turn_id":"%s","offset":%s}}],"id":2}' "$TURN" "$OFF" > /tmp/tp.json
    R=$(call "$(cat /tmp/tp.json)")
    OFF=$(printf '%s' "$R" | sed -n 's/.*"offset":\([0-9]*\).*/\1/p')

    # a confirm event carries an id; grab it the first time we see one
    if [ -z "$CONFIRMED" ]; then
        CID=$(printf '%s' "$R" | sed -n 's/.*"type":"confirm","timeout":[0-9]*,"args":{[^}]*},"id":"\([^"]*\)".*/\1/p')
        if [ -n "$CID" ]; then
            CONFIRMED="$CID"
            echo "  [$i] saw confirm id=$CID -> declining"
            printf '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","rpc",{"m":"approve","p":{"id":"%s","allow":false}}],"id":3}' "$CID" > /tmp/ta.json
            echo -n "     approve -> "; call "$(cat /tmp/ta.json)"
            echo
        fi
    fi

    if printf '%s' "$R" | grep -q '"finished":true'; then
        echo "  [$i] FINISHED"
        printf '%s' "$R" | head -c 700
        echo
        break
    fi
    AWAIT=$(printf '%s' "$R" | grep -o '"awaiting":"[^"]*"' | head -1)
    [ -n "$AWAIT" ] && echo "  [$i] waiting on $AWAIT"
    sleep 1
done
echo "  polls=$i  confirmed=$CONFIRMED"

echo
echo "===== event log ====="
tail -14 /tmp/gl-ai-agent/turns/$TURN.jsonl 2>/dev/null | cut -c1-190

echo
echo "===== markers ====="
echo -n "  awaiting: "; ls -1 /tmp/gl-ai-agent/awaiting/ 2>/dev/null | tr '\n' ' '; echo
echo -n "  claims:   "; ls -1 /tmp/gl-ai-agent/claims/ 2>/dev/null | tr '\n' ' '; echo
echo -n "  working:  "; ls -1 /tmp/gl-ai-agent/working/ 2>/dev/null | tr '\n' ' '; echo
echo -n "  approvals: "; cat /tmp/gl-ai-agent/approvals.json 2>/dev/null; echo
echo -n "  state:    "; sed 's/,"messages":.*//' /tmp/gl-ai-agent/state/$TURN.json 2>/dev/null | cut -c1-220; echo

rm -f /tmp/tq.json /tmp/ts.json /tmp/tp.json /tmp/ta.json
