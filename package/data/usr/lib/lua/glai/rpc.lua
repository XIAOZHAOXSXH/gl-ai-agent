--[[
  glai/rpc.lua - thin client for the GL SDK4 RPC endpoint.

  The GL admin UI talks to /rpc. Inside nginx we can reuse oui.rpc directly,
  which is both faster and avoids a loopback HTTP hop. The "glinet: 1" header
  is the SDK's own local-request escape hatch (used by GL's own tooling).
]]
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

local M = {}

-- Loaded eagerly, NOT via pcall. pcall here would be both pointless and
-- harmful: oui.rpc is always present inside the GL admin web tier, and a
-- failed require must surface as a real error rather than silently falling
-- through to the HTTP path.
local oui_rpc = require "oui.rpc"

--- Call an SDK4 RPC object method.
--
-- Never wrapped in pcall by callers: the underlying ubus call yields the
-- ngx_lua coroutine, and Lua 5.1 cannot yield across a pcall boundary.
-- @param object string  e.g. "wifi"
-- @param method string  e.g. "get_config"
-- @param args   table|nil
-- @return table|nil result, string|nil error
function M.call(object, method, args)
    local res, err = oui_rpc.call(object, method, args or {})
    if type(res) == "number" then
        -- oui.rpc reports failures as a numeric error code
        return nil, "rpc error " .. tostring(res) .. (err and (": " .. tostring(err)) or "")
    end
    if type(res) ~= "table" then res = {} end
    return res, nil
end

--- Read UCI state straight from the config files (no RPC needed).
function M.uci_get(config, section, option)
    local uci = require "uci"
    local cursor = uci.cursor()
    if option then
        return cursor:get(config, section, option)
    end
    return cursor:get_all(config, section)
end

return M
