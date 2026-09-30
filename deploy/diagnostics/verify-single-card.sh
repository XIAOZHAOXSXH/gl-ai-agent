#!/bin/sh
echo "===== confirmation cards in the newest turn (must be exactly 1) ====="
NEWEST=$(ls -1t /tmp/gl-ai-agent/turns/*.jsonl 2>/dev/null | head -1)
echo "  $NEWEST"
echo -n "  confirm events: "
grep -c '"type":"confirm"' "$NEWEST" 2>/dev/null || echo 0
echo -n "  tool_result events: "
grep -c '"type":"tool_result"' "$NEWEST" 2>/dev/null || echo 0
echo "  --- full log ---"
cat "$NEWEST" 2>/dev/null | cut -c1-200

echo
echo "===== approvals (must be empty) ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null || echo "  (absent)"

echo
echo "===== awaiting / claims (must be empty) ====="
ls -1 /tmp/gl-ai-agent/awaiting/ 2>/dev/null | sed 's/^/  awaiting: /'
ls -1 /tmp/gl-ai-agent/claims/ 2>/dev/null | sed 's/^/  claim: /'

echo
echo "===== router untouched ====="
echo -n "  2.4G main SSID: "; uci get wireless.default_radio0.ssid
if uci show wireless | grep -q "GL-Test-2G"; then
    echo "  LEAKED - GL-Test-2G is present"
else
    echo "  clean - GL-Test-2G absent"
fi
