#!/bin/sh
echo "===== approvals ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null || echo "  (absent)"
echo
echo "===== decided marker ====="
ls -1 /tmp/gl-ai-agent/decided/ 2>/dev/null || echo "  (none)"
echo "===== awaiting marker ====="
ls -1 /tmp/gl-ai-agent/awaiting/ 2>/dev/null || echo "  (none)"
echo
echo "===== trace tail ====="
tail -10 /tmp/gl-ai-agent/trace.log 2>/dev/null || echo "  (no trace)"
echo
echo "===== newest turn: event types ====="
T=$(ls -1t /tmp/gl-ai-agent/turns/*.jsonl 2>/dev/null | head -1)
echo "  $T"
for t in step tool_call confirm tool_result text done error saved; do
    n=$(grep -c "\"type\":\"$t\"" "$T" 2>/dev/null || echo 0)
    echo "    $t: $n"
done
