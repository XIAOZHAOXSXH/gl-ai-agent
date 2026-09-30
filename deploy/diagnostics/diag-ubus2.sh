#!/bin/sh
echo "=== ubus ==="
echo -n "  objects: "; ubus list 2>/dev/null | wc -l
pgrep -l ubusd || echo "  ubusd NOT running"
echo -n "  socket: "; ls -la /var/run/ubus/ubus.sock 2>/dev/null || echo "missing"

echo
echo "=== ujail / procd crashes ==="
dmesg | grep -c "SIGSEGV to ujail"
echo "  last 6 crash lines:"
dmesg | grep "ujail" | tail -6

echo
echo "=== procd ==="
pgrep -l procd || echo "  procd NOT running"
echo -n "  procd respawn count: "
dmesg | grep -c "procd"

echo
echo "=== memory / load ==="
free -m | head -2
uptime

echo
echo "=== opkg: what did the last install touch that matters ==="
echo -n "  gl-ai-agent files in /www: "
ls /www/views/gl-sdk4-ui-gl-ai.common.js /www/js/gl-ai-agent-boot.js 2>/dev/null | wc -l
echo "  (install does not restart any service; it only writes files)"
