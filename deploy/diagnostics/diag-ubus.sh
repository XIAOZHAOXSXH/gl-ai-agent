#!/bin/sh
# Plain-shell ubusd / filesystem diagnosis. Avoids parentheses and globs.
echo "=== ubusd running ==="
if pgrep ubusd >/dev/null 2>&1; then
    pgrep -l ubusd
else
    pgrep -l ubusd || echo "  NOT RUNNING"
fi

echo
echo "=== /var/run ==="
ls -la /var/run/ | head -20

echo
echo "=== mounts ==="
mount | grep -E "tmpfs|overlay" | head -10

echo
echo "=== disk ==="
df -h | head -8

echo
echo "=== write tests ==="
if echo x > /tmp/wt1 2>/dev/null; then echo "  /tmp writable"; rm -f /tmp/wt1; else echo "  /tmp NOT writable"; fi
if echo x > /var/run/wt2 2>/dev/null; then echo "  /var/run writable"; rm -f /var/run/wt2; else echo "  /var/run NOT writable"; fi
if echo x > /var/run/ubus/wt3 2>/dev/null; then echo "  /var/run/ubus writable"; rm -f /var/run/ubus/wt3; else echo "  /var/run/ubus NOT writable"; fi

echo
echo "=== dmesg tail ==="
dmesg | tail -8

echo
echo "=== start ubusd by hand ==="
rm -f /var/run/ubus/ubus.sock
/sbin/ubusd >/dev/null 2>&1 &
sleep 3
pgrep -l ubusd || echo "  ubusd still not running"
echo -n "  ubus objects: "
ubus -t 5 list 2>/dev/null | wc -l

echo
echo "=== last resort: procd restart ==="
if [ "$(ubus -t 5 list 2>/dev/null | wc -l)" = "0" ]; then
    /etc/init.d/rpcd restart 2>&1 | head -2
    /etc/init.d/ubus restart 2>&1 | head -2
    sleep 4
    echo -n "  ubus objects: "
    ubus -t 8 list 2>/dev/null | wc -l
fi
echo "=== end ==="
