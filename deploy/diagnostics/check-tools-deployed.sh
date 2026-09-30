#!/bin/sh
echo "===== is the pcall wrapper really gone? ====="
grep -n "tool failed" /usr/lib/lua/glai/tools.lua || echo "  (no 'tool failed' string - fix is deployed)"
echo "--- execute function ---"
sed -n '/^function M.execute/,/^end/p' /usr/lib/lua/glai/tools.lua
echo
echo "===== md5 of deployed tools.lua ====="
md5sum /usr/lib/lua/glai/tools.lua | cut -d' ' -f1
echo "--- size ---"
wc -c < /usr/lib/lua/glai/tools.lua
