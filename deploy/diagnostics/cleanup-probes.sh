#!/bin/sh
# Remove the throwaway probe RPC objects used during diagnosis.
for o in gl_probe gl_probe2 gl_probe3 gl_probe4 gl_probe5 gl_probe6; do
    rm -f /usr/lib/oui-httpd/rpc/$o
    rm -f /usr/share/gl-validator.d/$o.lua
done
echo "remaining rpc objects matching gl_:"
ls /usr/lib/oui-httpd/rpc/ | grep "^gl_" | sed 's/^/  /'
echo
echo "leftover probe files anywhere:"
ls /usr/lib/oui-httpd/rpc/gl_probe* 2>/dev/null || echo "  none"
