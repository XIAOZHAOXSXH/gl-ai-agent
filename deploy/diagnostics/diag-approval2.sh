#!/bin/sh
echo "===== newest turn event log ====="
NEWEST=$(ls -1t /tmp/gl-ai-agent/turns/*.jsonl 2>/dev/null | head -1)
echo "  $NEWEST"
cat "$NEWEST" 2>/dev/null | cut -c1-240

echo
echo "===== newest turn state (progress markers) ====="
NEWSTATE=$(ls -1t /tmp/gl-ai-agent/state/*.json 2>/dev/null | head -1)
echo "  $NEWSTATE"
node_absent=1
# print only the scalar fields, not the message history
sed 's/,"messages":.*//' "$NEWSTATE" 2>/dev/null | cut -c1-400

echo
echo "===== approvals ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null || echo "  (absent)"

echo
echo "===== recent nginx errors ====="
grep -v "rpc.lua:263" /var/log/nginx/error.log | tail -6 | cut -c1-220
