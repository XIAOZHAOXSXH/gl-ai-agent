#!/bin/sh
# Why does oui.rpc not find methods that a plain dofile clearly exposes?
# Instrument a throwaway object that mirrors gl_ai exactly.
mkdir -p /usr/lib/oui-httpd/rpc
cat > /usr/lib/oui-httpd/rpc/gl_probe <<'LUA'
local fs = require "oui.fs"
local log = {}

log.access = fs.access("/usr/lib/oui-httpd/rpc/gl_probe")
log.body = "probe-ok"

local chunk, err = loadfile("/usr/lib/lua/glai/rpc_entry.lua")
log.loadfile_ok = (chunk ~= nil)
log.loadfile_err = err and tostring(err) or ""

local mod
if chunk then
    local ok, m = pcall(chunk)
    log.pcall_ok = ok
    mod = m
    log.mod_type = type(m)
end

log.has_selftest = (type(mod) == "table") and (type(mod.selftest) == "function") or false
log.fs_type = type(fs.access)

return {
    probe = function()
        return log
    end,
}
LUA
chmod 755 /usr/lib/oui-httpd/rpc/gl_probe

echo "=== plain lua can dofile it ==="
lua -e 'local t = dofile("/usr/lib/oui-httpd/rpc/gl_probe"); print("  exports probe: " .. tostring(t.probe ~= nil))'

echo
echo "=== does oui.rpc reach it? ==="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_probe","probe",{}],"id":1}' > /tmp/pp.json
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/pp.json | head -c 600
echo
rm -f /tmp/pp.json
