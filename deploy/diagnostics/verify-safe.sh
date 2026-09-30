#!/bin/sh
echo "===== 2.4G main SSID (must still be GL-MG1300-caa) ====="
uci get wireless.default_radio0.ssid
echo -n "  changed to GL-Test-2G? "
if [ "$(uci get wireless.default_radio0.ssid)" = "GL-Test-2G" ]; then echo "YES - THE WRITE LEAKED"; else echo "no - safe"; fi

echo
echo "===== wifi.get_config SSIDs ====="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","wifi","get_config",{}],"id":1}' > /tmp/w.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/w.json \
  | sed 's/},{/}\n{/g' | grep -o '"ssid":"[^"]*"'
rm -f /tmp/w.json

echo
echo "===== stale approvals (should be empty) ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null || echo "  (absent)"
echo
echo "===== awaiting markers ====="
ls -la /tmp/gl-ai-agent/awaiting/ 2>/dev/null | tail -5
