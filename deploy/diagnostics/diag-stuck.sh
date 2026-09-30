#!/bin/sh
echo "===== markers ====="
echo -n "  awaiting: "; ls -1 /tmp/gl-ai-agent/awaiting/ 2>/dev/null | tr '\n' ' '; echo
echo -n "  claims:   "; ls -1 /tmp/gl-ai-agent/claims/ 2>/dev/null | tr '\n' ' '; echo
echo -n "  working:  "; ls -1 /tmp/gl-ai-agent/working/ 2>/dev/null | tr '\n' ' '; echo
echo -n "  approvals: "; cat /tmp/gl-ai-agent/approvals.json 2>/dev/null; echo

echo
echo "===== newest state (scalars only) ====="
S=$(ls -1t /tmp/gl-ai-agent/state/*.json 2>/dev/null | head -1)
echo "  $S"
sed 's/,"messages":.*//; s/,"pending":{.*//' "$S" 2>/dev/null | cut -c1-400

echo
echo "===== newest turn log (last 10) ====="
T=$(ls -1t /tmp/gl-ai-agent/turns/*.jsonl 2>/dev/null | head -1)
echo "  $T"
echo -n "  tool_call:   "; grep -c '"type":"tool_call"' "$T" 2>/dev/null
echo -n "  confirm:     "; grep -c '"type":"confirm"' "$T" 2>/dev/null
echo -n "  tool_result: "; grep -c '"type":"tool_result"' "$T" 2>/dev/null
echo -n "  done:        "; grep -c '"type":"done"' "$T" 2>/dev/null
echo -n "  error:       "; grep -c '"type":"error"' "$T" 2>/dev/null
echo "  --- tail ---"
tail -6 "$T" 2>/dev/null | cut -c1-170

echo
echo "===== lua errors ====="
grep -i "lua" /var/log/nginx/error.log | grep -vE "rpc.lua:263|oui-ws" | tail -5 | cut -c1-200
