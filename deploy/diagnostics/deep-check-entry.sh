#!/bin/sh
echo "===== 1. deployed entry file ====="
wc -c < /usr/lib/oui-httpd/rpc/gl_ai
md5sum /usr/lib/oui-httpd/rpc/gl_ai | cut -d' ' -f1
echo "--- does it define rpc? ---"
grep -c "rpc = dispatch" /usr/lib/oui-httpd/rpc/gl_ai
echo "--- first 3 lines ---"
head -3 /usr/lib/oui-httpd/rpc/gl_ai

echo
echo "===== 2. load it the way oui.rpc does, in plain lua ====="
lua -e '
local script = "/usr/lib/oui-httpd/rpc/gl_ai"
local ok, tb = pcall(dofile, script)
print("  dofile ok: " .. tostring(ok))
if not ok then print("  err: " .. tostring(tb)); os.exit(1) end
print("  type: " .. type(tb))
local names = {}
for k, v in pairs(tb) do
    if type(v) == "function" then names[#names+1] = k end
end
table.sort(names)
print("  exports: " .. table.concat(names, ", "))
'

echo
echo "===== 3. is there a shadowing copy? ====="
find / -name "gl_ai" -not -path "/proc/*" 2>/dev/null | sed 's/^/  /'

echo
echo "===== 4. what does the rpc module actually see? ====="
lua -e '
local ok, rpc = pcall(require, "oui.rpc")
if not ok then print("  oui.rpc unloadable outside nginx: " .. tostring(rpc)); os.exit(0) end
print("  oui.rpc loaded (unexpected outside nginx)")
'

echo
echo "===== 5. nginx worker: fresh or old? ====="
ps w | grep "[n]ginx"

echo
echo "===== 6. simplest possible probe: does an existing method still work ====="
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","get_config",{}],"id":1}' > /tmp/p1.json
echo -n "  get_config: "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/p1.json | head -c 90
echo
printf '%s' '{"jsonrpc":"2.0","method":"call","params":["","gl_ai","selftest",{}],"id":1}' > /tmp/p2.json
echo -n "  selftest:   "
curl -s -H "glinet:1" -X POST http://127.0.0.1/rpc --data-binary @/tmp/p2.json | head -c 90
echo
rm -f /tmp/p1.json /tmp/p2.json
