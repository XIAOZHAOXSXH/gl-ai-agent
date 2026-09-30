#!/bin/sh
# Recover the GL service tier: ubusd is alive but no longer accepting clients,
# so every ubus consumer (gl-session, nginx lua, opkg, ...) is broken.
# Order matters: ubusd first, then the services that register on it.

echo "=== before ==="
echo -n "  ubus objects: "; ubus -t 5 list 2>/dev/null | wc -l

if [ "$(ubus -t 5 list 2>/dev/null | wc -l)" = "0" ]; then
    echo "  restarting ubusd"
    UBPID=$(ps w | grep "[u]busd" | awk '{print $1}' | head -1)
    [ -n "$UBPID" ] && kill "$UBPID" 2>/dev/null
    sleep 5
    echo -n "  ubusd: "; ps w | grep "[u]busd" | head -1
    echo -n "  ubus objects after ubusd respawn: "; ubus -t 8 list 2>/dev/null | wc -l
fi

if [ "$(ubus -t 8 list 2>/dev/null | wc -l)" = "0" ]; then
    echo "  still empty; restarting the registrar services"
    for s in gl-ngx-session gl-clients gl-cloud rpcd; do
        if [ -x "/etc/init.d/$s" ]; then
            echo "    restart $s"
            "/etc/init.d/$s" restart >/dev/null 2>&1
            sleep 1
        fi
    done
    sleep 3
fi

if [ "$(ubus -t 8 list 2>/dev/null | wc -l)" = "0" ]; then
    echo "  restarting nginx and the network tier"
    /etc/init.d/nginx restart >/dev/null 2>&1
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    /etc/init.d/network reload >/dev/null 2>&1
    sleep 6
fi

echo
echo "=== after ==="
echo -n "  ubus objects: "; ubus -t 8 list 2>/dev/null | wc -l
echo "  key services:"
ubus -t 8 list 2>/dev/null | grep -E "^(gl-session|gl-clients|system|uci|service|network|wifi)$" | sed 's/^/    /'

echo
echo "=== web + rpc ==="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","system","get_info",{}],"id":1}' > /tmp/t.json
echo -n "  gl_home.html: "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/gl_home.html
echo -n "  system.get_info: "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/t.json | head -c 150
echo
echo -n "  gl_ai.get_config: "
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","get_config",{}],"id":1}' > /tmp/t.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/t.json | head -c 120
echo
rm -f /tmp/t.json
echo "=== done ==="
