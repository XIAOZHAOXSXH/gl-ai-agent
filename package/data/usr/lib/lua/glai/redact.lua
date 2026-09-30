--[[
  glai/redact.lua - privacy filter for anything that leaves the router.

  Tool results are fed to a third-party model, so device names and addresses
  are minimised before they go out:
    * MAC addresses become stable short tokens (M1, M2, ...) and the mapping
      is kept locally so a later tool call can be resolved back.
    * IPv4 addresses keep only their last octet.
    * Passwords / keys are replaced outright.

  Stable tokens matter: the model must be able to say "limit M3" and have that
  resolve to the right device on the next tool call.
]]
local M = {}

--- Create a per-request redaction context.
function M.new(enabled)
    return {
        enabled = enabled ~= false,
        mac_to_token = {},
        token_to_mac = {},
        counter = 0,
    }
end

function M.token_for(ctx, mac)
    if not ctx or not ctx.enabled or not mac then return mac end
    local token = ctx.mac_to_token[mac]
    if not token then
        ctx.counter = ctx.counter + 1
        token = "M" .. ctx.counter
        ctx.mac_to_token[mac] = token
        ctx.token_to_mac[token] = mac
    end
    return token
end

function M.resolve(ctx, token)
    if not ctx then return token end
    return ctx.token_to_mac[token] or token
end

function M.mac(ctx, value)
    if not value then return value end
    if not ctx or not ctx.enabled then return value end
    if not value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return value end
    return M.token_for(ctx, value:upper())
end

function M.ip(ctx, value)
    if not value or not ctx or not ctx.enabled then return value end
    local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a then return "*.*.*." .. d end
    return value
end

--- Recursively sanitise a decoded JSON structure.
function M.value(ctx, v, depth)
    depth = depth or 0
    if depth > 8 then return "..." end
    local t = type(v)
    if t == "string" then
        if v:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
            return M.mac(ctx, v)
        end
        if v:match("^%d+%.%d+%.%d+%.%d+$") then
            return M.ip(ctx, v)
        end
        return v
    end
    if t ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do
        -- never forward credential material
        if k == "key" or k == "password" or k == "passwd" or k == "psk"
            or k == "wpakey" or k == "api_key" or k == "token" or k == "secret" then
            out[k] = (val ~= nil and val ~= "") and "(set)" or "(empty)"
        else
            out[k] = M.value(ctx, val, depth + 1)
        end
    end
    return out
end

return M
