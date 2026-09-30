#!/bin/sh
echo "===== does the file have selftest? ====="
grep -c "function M.selftest" /usr/lib/lua/glai/rpc_entry.lua
echo "--- file size / mtime ---"
ls -la /usr/lib/lua/glai/rpc_entry.lua
echo
echo "--- tail of the file ---"
tail -8 /usr/lib/lua/glai/rpc_entry.lua
echo
echo "===== can it be loaded and does it export the method ====="
lua -e '
local ok, t = pcall(dofile, "/usr/lib/oui-httpd/rpc/gl_ai")
if not ok then print("  dofile FAIL: " .. tostring(t)); os.exit(1) end
print("  dofile OK, type=" .. type(t))
local n = 0
for k, v in pairs(t) do
    if type(v) == "function" then
        n = n + 1
        if k == "selftest" then print("  selftest exported: YES") end
    end
end
print("  functions exported: " .. n)
'
echo
echo "===== validator keys ====="
grep -c "selftest" /usr/share/gl-validator.d/gl_ai.lua
