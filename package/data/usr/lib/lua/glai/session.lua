--[[
  glai/session.lua - conversation persistence.

  A session is a small JSON document on the router's overlay filesystem, so
  conversations survive a reboot. History is bounded on write: the agent only
  ever replays a recent window, and unbounded growth would eat both flash and
  the model's context budget.
]]
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

local M = {}

M.DIR = "/etc/gl-ai-agent/sessions"
local MAX_STORED = 40      -- messages kept on disk
local MAX_SESSIONS = 20    -- oldest are pruned beyond this

local function path_for(id)
    if type(id) ~= "string" or not id:match("^[%w_%-]+$") then return nil end
    return M.DIR .. "/" .. id .. ".json"
end

local function ensure_dir()
    os.execute("mkdir -p " .. M.DIR)
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    local ok, decoded = pcall(cjson.decode, raw)
    if ok then return decoded end
    return nil
end

local function write_json(path, value)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(cjson.encode(value))
    f:close()
    return true
end

function M.new_id()
    return os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(math.random(1000, 9999))
end

function M.load(id)
    local p = path_for(id)
    if not p then return nil, "bad session id" end
    local data = read_json(p)
    if not data then return nil, "session not found" end
    return data
end

function M.save(session)
    ensure_dir()
    if not session or not session.id then return false, "no id" end
    local p = path_for(session.id)
    if not p then return false, "bad id" end

    -- bound the stored history
    if session.messages and #session.messages > MAX_STORED + 1 then
        local system = session.messages[1]
        local rest = {}
        for i = #session.messages - MAX_STORED + 1, #session.messages do
            rest[#rest + 1] = session.messages[i]
        end
        while rest[1] and rest[1].role == "tool" do table.remove(rest, 1) end
        session.messages = { system }
        for _, m in ipairs(rest) do session.messages[#session.messages + 1] = m end
    end

    session.updated = os.time()
    return write_json(p, session)
end

function M.create(title)
    ensure_dir()
    local session = {
        id = M.new_id(),
        title = title or "New chat",
        created = os.time(),
        updated = os.time(),
        messages = {},
    }
    M.save(session)
    return session
end

function M.list()
    ensure_dir()
    local out = {}
    local p = io.popen("ls -1t " .. M.DIR .. "/*.json 2>/dev/null")
    if p then
        for line in p:lines() do
            local id = line:match("([^/]+)%.json$")
            if id then
                local s = read_json(line)
                if s then
                    table.insert(out, {
                        id = s.id or id,
                        title = s.title or "Chat",
                        updated = s.updated or 0,
                        messages = s.messages and #s.messages or 0,
                    })
                end
            end
        end
        p:close()
    end
    return out
end

function M.remove(id)
    local p = path_for(id)
    if not p then return false end
    os.remove(p)
    return true
end

--- Derive a short title from the first user message.
function M.auto_title(text)
    if not text then return "New chat" end
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > 28 then text = text:sub(1, 28) .. "…" end
    return text
end

--- Tell the model what it did, in one line, so history stays readable.
function M.touch(session, kind)
    session.last_kind = kind
    session.updated = os.time()
end

M.MAX_SESSIONS = MAX_SESSIONS
return M
