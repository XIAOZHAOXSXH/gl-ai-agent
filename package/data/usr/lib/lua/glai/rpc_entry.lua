--[[
  glai/rpc_entry.lua - SDK4 RPC object "gl_ai".

  Reached from the browser exactly like every other GL page:
      POST /rpc
      {"jsonrpc":"2.0","method":"call",
       "params":[<sid>,"gl_ai","get_config",{}],"id":1}

  Keeping the config/history surface on the SDK's own RPC bus means the agent
  page inherits the admin session, CSRF handling and access control of the
  stock UI instead of inventing a second API surface.
]]
local cjson = require "cjson"
local config = require "glai.config"
local session = require "glai.session"
local tools = require "glai.tools"
local llm = require "glai.llm"
local agent = require "glai.agent"

local M = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- configuration
-- ---------------------------------------------------------------------------

function M.get_config()
    return config.public()
end

--- Update provider/agent settings. An empty api_key means "keep the old one"
--- so the masked field in the UI can round-trip safely.
function M.set_config(params)
    params = params or {}
    local patch = {}

    if params.provider then
        patch.provider = {}
        for _, k in ipairs({
            "protocol", "base_url", "model", "temperature", "max_tokens", "timeout",
            "proxy", "verify_tls", "stream",
        }) do
            if params.provider[k] ~= nil then patch.provider[k] = params.provider[k] end
        end
        if params.provider.api_key and trim(params.provider.api_key) ~= "" then
            patch.provider.api_key = trim(params.provider.api_key)
        end
        if params.provider.clear_api_key then
            patch.provider.api_key = ""
        end
    end

    if params.agent then
        patch.agent = {}
        for _, k in ipairs({
            "permission", "max_steps", "history_turns", "language",
            "send_device_context", "redact_client_identity", "confirm_timeout",
        }) do
            if params.agent[k] ~= nil then patch.agent[k] = params.agent[k] end
        end
    end

    config.update(patch)
    return config.public()
end

function M.test_connection(params)
    local cfg = config.load()
    local provider = cfg.provider

    -- allow testing unsaved values straight from the form
    if params and params.provider then
        for _, k in ipairs({
            "protocol", "base_url", "model", "temperature", "max_tokens", "timeout",
            "proxy", "verify_tls", "stream",
        }) do
            if params.provider[k] ~= nil and params.provider[k] ~= "" then
                provider[k] = params.provider[k]
            end
        end
        if params.provider.api_key and trim(params.provider.api_key) ~= "" then
            provider.api_key = trim(params.provider.api_key)
        end
    end

    if provider.base_url == "" or provider.model == "" then
        return { ok = false, error = "base_url and model are required" }
    end
    if provider.api_key == "" and provider.protocol ~= "gemini" then
        return { ok = false, error = "api_key is required" }
    end

    local res, err = llm.test(provider)
    if not res then
        return { ok = false, error = tostring(err) }
    end
    return res
end

-- ---------------------------------------------------------------------------
-- capability + tool introspection
-- ---------------------------------------------------------------------------

function M.get_tools()
    return { tools = tools.manifest() }
end

function M.get_capabilities()
    local rpc = require "glai.rpc"
    local info = rpc.call("system", "get_info", {}) or {}
    local present = {}
    -- which optional SDK objects does this model actually expose?
    local p = io.popen("ls -1 /usr/lib/oui-httpd/rpc/ 2>/dev/null")
    if p then
        for line in p:lines() do
            present[line:gsub("%.so$", "")] = true
        end
        p:close()
    end
    return {
        model = info.model,
        firmware = info.firmware_version,
        hardware_feature = info.hardware_feature or {},
        objects = present,
    }
end

-- ---------------------------------------------------------------------------
-- sessions
-- ---------------------------------------------------------------------------

function M.list_sessions()
    return { sessions = session.list() }
end

function M.get_session(params)
    params = params or {}
    local sess, err = session.load(params.id)
    if not sess then return { error = tostring(err) } end
    -- hand back only what the UI renders, not internal tool payloads
    local view = {}
    for _, m in ipairs(sess.messages or {}) do
        if m.role == "user" or (m.role == "assistant" and m.content and m.content ~= "") then
            table.insert(view, { role = m.role, content = m.content })
        end
    end
    return { id = sess.id, title = sess.title, messages = view }
end

function M.delete_session(params)
    params = params or {}
    if not params.id then return { ok = false, error = "id required" } end
    session.remove(params.id)
    return { ok = true }
end

function M.new_session()
    local sess = session.create()
    return { id = sess.id, title = sess.title }
end

-- ---------------------------------------------------------------------------
-- interaction
-- ---------------------------------------------------------------------------

--- Begin a turn. Returns immediately; the browser then polls `poll`.
function M.chat(params)
    params = params or {}
    local turns = require "glai.turns"
    local res, err = turns.start(params)
    if not res then return { error = tostring(err) } end
    return res
end

--- Fetch events written since `offset` for a turn.
function M.poll(params)
    params = params or {}
    local turns = require "glai.turns"
    return turns.poll(params.turn_id, params.offset)
end

--- Answer a confirmation card.
function M.approve(params)
    params = params or {}
    if not params.id then return { ok = false, error = "id required" } end
    local turns = require "glai.turns"
    local ok = turns.decide(params.id, params.allow and true or false)
    return { ok = ok }
end

--- Which confirmations are still waiting (lets the UI recover after a reload).
function M.pending_approvals()
    local turns = require "glai.turns"
    local all = turns.read_approvals()
    local out = {}
    for id, state in pairs(all) do
        if state == "pending" then out[#out + 1] = id end
    end
    return { pending = out }
end

function M.cancel()
    -- A turn runs in a background timer, so there is no request to abort; the UI
    -- simply stops polling and the run finishes on its own within its step
    -- budget. Nothing is left half-applied because every write is confirmed
    -- before it runs.
    return { ok = true }
end

-- ---------------------------------------------------------------------------
-- self test
-- ---------------------------------------------------------------------------

--- Exercise every read-only tool for real, inside the nginx request context.
--
-- This exists because the tools reach the router through oui.rpc, which needs
-- `ngx`; running them from a bare `lua -e` shell always fails. This endpoint is
-- therefore the only honest way to verify the tool layer, and it doubles as the
-- "is the assistant actually working?" check in the UI.
function M.selftest()
    local results = {}
    local passed, failed = 0, 0

    -- Schema sanity first. A single malformed parameter object makes the whole
    -- request fail upstream with an opaque HTTP 400, so catching it here turns a
    -- mystifying failure into a named one. The specific trap: JSON Schema
    -- forbids an empty `required`, and cjson encodes an empty Lua table as {}
    -- rather than [], which gateways reject.
    local schema_problems = {}
    for _, s in ipairs(tools.schemas()) do
        local fn = s["function"]
        local p = fn.parameters
        if type(p) ~= "table" or p.type ~= "object" then
            schema_problems[#schema_problems + 1] = fn.name .. ": parameters is not an object schema"
        end
        if p and p.required ~= nil then
            if type(p.required) ~= "table" or next(p.required) == nil then
                schema_problems[#schema_problems + 1] = fn.name .. ": 'required' must be a non-empty array or absent"
            end
        end
        if p and p.properties ~= nil and type(p.properties) ~= "table" then
            schema_problems[#schema_problems + 1] = fn.name .. ": 'properties' must be an object"
        end
    end

    for _, tool in ipairs(tools.registry) do
        if tool.risk == "low" then
            local t0 = ngx.now()
            local res, err = tools.execute(tool, {})
            local ms = math.floor((ngx.now() - t0) * 1000)
            if res then
                passed = passed + 1
                local encoded = cjson.encode(res)
                results[#results + 1] = {
                    name = tool.name,
                    ok = true,
                    ms = ms,
                    bytes = #encoded,
                    -- a short sample makes failures diagnosable from the UI
                    sample = encoded:sub(1, 120),
                }
            else
                failed = failed + 1
                results[#results + 1] = {
                    name = tool.name,
                    ok = false,
                    ms = ms,
                    error = tostring(err),
                }
            end
        end
    end

    return {
        ok = (failed == 0 and #schema_problems == 0),
        passed = passed,
        failed = failed,
        total = passed + failed,
        schema_problems = schema_problems,
        configured = config.is_configured(),
        tools = results,
    }
end

return M
