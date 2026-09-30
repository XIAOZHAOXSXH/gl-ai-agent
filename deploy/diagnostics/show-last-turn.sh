#!/bin/sh
echo "===== newest turn event log ====="
NEWEST=$(ls -1t /tmp/gl-ai-agent/turns/*.jsonl 2>/dev/null | head -1)
echo "  $NEWEST"
cat "$NEWEST" 2>/dev/null | cut -c1-300

echo
echo "===== approvals ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null || echo "  (none)"

echo
echo "===== turn state files ====="
ls -la /tmp/gl-ai-agent/state/ 2>/dev/null | tail -3

echo
echo "===== recent nginx errors (non-routine) ====="
grep -v "rpc.lua:263" /var/log/nginx/error.log | tail -8 | cut -c1-240
