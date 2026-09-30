--[[
  glai/config.lua - persisted agent configuration.

  Stored at /etc/gl-ai-agent/config.json with mode 0600 because it holds the
  user's API key. Nothing here is ever written to logs.
]]
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

local M = {}

M.DIR = "/etc/gl-ai-agent"
M.FILE = M.DIR .. "/config.json"

local DEFAULTS = {
    version = 1,
    provider = {
        -- No vendor is baked in: the user supplies base_url + model + key.
        protocol = "openai",          -- openai | anthropic | gemini
        base_url = "",
        model = "",
        api_key = "",
        temperature = 0.2,
        max_tokens = 1024,
        timeout = 60,
        extra_headers = {},
        -- route the API call through a gateway/proxy when the router cannot
        -- reach the provider directly
        proxy = "",
        -- Verify the provider's TLS chain.
        --
        -- Routers on guest, hotel or captive networks commonly sit behind an
        -- intercepting proxy that presents a self-signed certificate, which
        -- fails verification with "self signed certificate in certificate
        -- chain". Those users need a way through, so this is exposed as an
        -- advanced option - but disabling verification is a real downgrade, so
        -- it stays on by default and the UI labels it plainly.
        verify_tls = true,
        -- Ask the provider to stream tokens.
        --
        -- Off by default. A turn runs inside an ngx.timer, and holding a
        -- long-lived streaming read across a timer coroutine's lifetime is not
        -- reliable - it surfaces as "can't resume a dead coroutine". A
        -- non-streaming call is a single request/response, which is rock solid
        -- here; the UI still animates the reply in progressively, so the felt
        -- experience is nearly identical. Turn this on for providers and
        -- networks where it proves stable.
        stream = false,
    },
    agent = {
        permission = "ask",           -- readonly | ask | auto
        max_steps = 8,
        history_turns = 12,
        language = "auto",            -- auto | zh-cn | en
        send_device_context = true,
        redact_client_identity = true,
        confirm_timeout = 45,
    },
}

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deep_copy(val) end
    return out
end

--- Merge persisted values over the defaults so new keys appear on upgrade.
local function merge(base, over)
    if type(over) ~= "table" then return base end
    for k, v in pairs(over) do
        if type(v) == "table" and type(base[k]) == "table" then
            merge(base[k], v)
        else
            base[k] = v
        end
    end
    return base
end

local function ensure_dir()
    os.execute("mkdir -p " .. M.DIR .. " " .. M.DIR .. "/sessions")
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

--- Load configuration. On first run this creates the default file.
function M.load()
    ensure_dir()
    local raw = read_file(M.FILE)
    local cfg = deep_copy(DEFAULTS)
    if raw and #raw > 0 then
        local ok, decoded = pcall(cjson.decode, raw)
        if ok and type(decoded) == "table" then
            merge(cfg, decoded)
        end
    else
        M.save(cfg)
    end
    return cfg
end

function M.save(cfg)
    ensure_dir()
    write_file(M.FILE, cjson.encode(cfg))
    os.execute("chmod 600 " .. M.FILE)
    return true
end

--- Merge a partial update (as sent by the settings UI) and persist.
function M.update(patch)
    local cfg = M.load()
    merge(cfg, patch or {})
    M.save(cfg)
    return cfg
end

--- Public projection: never reveal the API key, only whether one is set.
function M.public(cfg)
    cfg = cfg or M.load()
    return {
        provider = {
            protocol = cfg.provider.protocol,
            base_url = cfg.provider.base_url,
            model = cfg.provider.model,
            has_api_key = (cfg.provider.api_key ~= nil and cfg.provider.api_key ~= ""),
            api_key_hint = M.key_hint(cfg.provider.api_key),
            temperature = cfg.provider.temperature,
            max_tokens = cfg.provider.max_tokens,
            timeout = cfg.provider.timeout,
            proxy = cfg.provider.proxy,
            verify_tls = cfg.provider.verify_tls ~= false,
            stream = cfg.provider.stream == true,
        },
        agent = cfg.agent,
        configured = M.is_configured(cfg),
    }
end

function M.key_hint(key)
    if not key or key == "" then return "" end
    if #key <= 4 then return "****" end
    return "****" .. key:sub(-4)
end

function M.is_configured(cfg)
    cfg = cfg or M.load()
    local p = cfg.provider
    return (p.base_url ~= "" and p.model ~= "" and p.api_key ~= "")
end

M.DEFAULTS = DEFAULTS
return M
