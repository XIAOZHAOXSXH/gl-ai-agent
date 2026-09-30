#!/bin/sh
# Restore ubus without rebooting the device.
#
# Symptom: ubusd and procd are both running, no ujail segfaults, plenty of RAM,
# yet "ubus list" returns nothing and /rpc fails inside oui-rpc.lua because
# ubus.call() returns nil. The daemon has stopped answering on its socket.
#
# Fix: replace ubusd, then restart the services that re-register on it. The GL
# stack registers lazily via procd, so a couple of restarts bring the objects
# back without a reboot.

echo "=== before ==="
echo -n "  ubus objects: "; ubus list 2>/dev/null | wc -l
echo -n "  ubusd pid: "; pgrep ubusd || echo none

echo
echo "=== replace ubusd ==="
kill $(pgrep ubusd) 2>/dev/null
sleep 2
# procd normally respawns it; start it explicitly if it did not come back
if ! pgrep ubusd >/dev/null 2>&1; then
    rm -f /var/run/ubus/ubus.sock
    /sbin/ubusd >/dev/null 2>&1 &
    sleep 3
fi
echo -n "  ubusd pid now: "; pgrep ubusd || echo none
echo -n "  ubus objects: "; ubus list 2>/dev/null | wc -l

echo
echo "=== re-register the GL services ==="
# gl-ngx-session serves the login RPC; gl-clients serves the client list.
# Both are procd services and come back on restart.
for s in gl-ngx-session gl-clients gl-cloud; do
    if [ -x "/etc/init.d/$s" ]; then
        printf "  restart %-16s " "$s"
        "/etc/init.d/$s" restart >/dev/null 2>&1
        sleep 1
        if pgrep -f "$s" >/dev/null 2>&1; then echo "running"; else echo "(not running)"; fi
    fi
done
sleep 2

echo
echo "=== after ==="
echo -n "  ubus objects: "; ubus list 2>/dev/null | wc -l
echo "  key services:"
ubus list 2>/dev/null | grep -E "^(gl-session|gl-clients|system|uci|service|network|wifi)$" | sed 's/^/    /'

echo
echo "=== login path works again? ==="
printf '%s' '{"jsonrpc":"2.0","method":"challenge","params":{"username":"root"},"id":1}' > /tmp/ch.json
echo -n "  rpc challenge: "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/ch.json | head -c 160
echo
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","system","get_info",{}],"id":1}' > /tmp/si.json
echo -n "  system.get_info: "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/si.json | head -c 120
echo
rm -f /tmp/ch.json /tmp/si.json
echo "=== done ==="
