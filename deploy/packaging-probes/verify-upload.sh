#!/bin/sh
echo "===== 1. local vs remote byte size ====="
echo -n "  rpc_entry.lua on device: "; wc -c < /usr/lib/lua/glai/rpc_entry.lua
echo -n "  md5: "; md5sum /usr/lib/lua/glai/rpc_entry.lua | cut -d' ' -f1

echo
echo "===== 2. is selftest really in the remote file ====="
grep -n "M.selftest" /usr/lib/lua/glai/rpc_entry.lua

echo
echo "===== 3. simulate what oui.rpc.call does ====="
lua -e '
local fs_ok = pcall(require, "oui.fs")
print("  oui.fs loadable outside nginx: " .. tostring(fs_ok))
local script = "/usr/lib/oui-httpd/rpc/gl_ai"
local ok, tb = pcall(dofile, script)
print("  dofile ok: " .. tostring(ok))
if ok then
    print("  type: " .. type(tb))
    if type(tb) == "table" then
        local n = 0
        for k, v in pairs(tb) do
            if type(v) == "function" then n = n + 1 end
        end
        print("  functions: " .. n)
        print("  has selftest: " .. tostring(tb.selftest ~= nil))
    end
else
    print("  error: " .. tostring(tb))
end
'

echo
echo "===== 4. nginx worker age vs file mtime ====="
echo -n "  worker started (etimes seconds): "
for p in $(pidof nginx); do
    if [ -r /proc/$p/stat ]; then
        :
    fi
done
ps -o pid,etime,comm -p $(pidof nginx) 2>/dev/null || ps w | grep "[n]ginx"

echo
echo "===== 5. try a BRAND NEW method name to see if new code is seen at all ====="
grep -c "function M.get_version" /usr/lib/lua/glai/rpc_entry.lua
