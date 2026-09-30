#!/bin/sh
# Confirm the router's WiFi configuration was NOT changed by the declined
# approval - this is the safety property the confirmation gate exists for.
echo "===== uci wireless (source of truth) ====="
uci show wireless | grep -E "ssid=|key=" | sed 's/key=.*/key=***/' 

echo
echo "===== wifi.get_config SSIDs ====="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","wifi","get_config",{}],"id":1}' > /tmp/w.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/w.json \
  | sed 's/},{/}\n{/g' | grep -o '"ssid":"[^"]*"'

echo
echo "===== is GL-Test-2G anywhere? ====="
if uci show wireless | grep -q "GL-Test-2G"; then
    echo "  FOUND - the write leaked through!"
else
    echo "  absent - nothing was written (correct)"
fi

echo
echo "===== pending approvals (should be empty) ====="
cat /tmp/gl-ai-agent/approvals.json 2>/dev/null || echo "  (file absent)"
rm -f /tmp/w.json
