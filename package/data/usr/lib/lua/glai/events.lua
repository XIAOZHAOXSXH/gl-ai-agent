--[[
  glai/events.lua - append-only event log for one agent turn.

  Why a log file instead of a streaming HTTP response:

  A live SSE endpoint would need its own nginx `location`, and adding one means
  reloading the web server on install - unacceptable for a plugin that is meant
  to slip into a running router. So a turn runs in a background ngx.timer and
  appends newline-delimited JSON here; the browser polls with a byte offset and
  renders whatever is new.

  The practical effect in the UI is identical (text appears progressively), and
  the install/upgrade path never touches nginx.

  Layout:
    /tmp/gl-ai-agent/turns/<turn-id>.jsonl    one JSON object per line
  The offset returned by `read` is a byte position, so re-reading is cheap and
  a slow browser never skips events.
]]
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

local M = {}

M.DIR = "/tmp/gl-ai-agent/turns"
local MAX_EVENTS = 2000          -- hard cap per turn, protects against a runaway loop
local MAX_BYTES = 1 * 1024 * 1024

local function ensure_dir()
    os.execute("mkdir -p " .. M.DIR)
end

local function path_for(id)
    if type(id) ~= "string" or not id:match("^[%w_%-]+$") then return nil end
    return M.DIR .. "/" .. id .. ".jsonl"
end

function M.new_id()
    return os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(math.random(100000, 999999))
end

function M.create(id)
    ensure_dir()
    local f = io.open(path_for(id), "w")
    if f then f:close() end
    return id
end

--- Append one event. Returns false once the turn exceeds its budget.
function M.append(id, event)
    local path = path_for(id)
    if not path then return false end

    local f = io.open(path, "a")
    if not f then return false end

    local size = f:seek("end") or 0
    if size > MAX_BYTES then
        f:close()
        return false
    end

    f:write(cjson.encode(event), "\n")
    f:close()
    return true
end

--- Read every event written after `offset`.
-- @return table events, number next_offset, boolean finished
function M.read(id, offset)
    local path = path_for(id)
    if not path then return {}, offset or 0, false end

    local f = io.open(path, "r")
    if not f then return {}, offset or 0, false end

    local size = f:seek("end") or 0
    local from = tonumber(offset) or 0
    if from > size then from = 0 end          -- log was rotated/truncated
    f:seek("set", from)

    local events = {}
    local count = 0
    for line in f:lines() do
        if line ~= "" then
            local ok, ev = pcall(cjson.decode, line)
            if ok and type(ev) == "table" then
                events[#events + 1] = ev
                count = count + 1
                if count >= MAX_EVENTS then break end
            end
        end
    end
    local next_offset = f:seek("cur") or size
    f:close()

    -- the run always terminates with one of these
    local finished = false
    for _, ev in ipairs(events) do
        if ev.type == "done" or ev.type == "error" or ev.type == "saved" then
            finished = true
        end
    end
    return events, next_offset, finished
end

--- Remove a turn's log once the browser has consumed it.
function M.remove(id)
    local path = path_for(id)
    if path then os.remove(path) end
end

--- Drop logs older than `max_age` seconds so /tmp cannot grow without bound.
function M.sweep(max_age)
    max_age = max_age or 3600
    ensure_dir()
    local now = os.time()
    local p = io.popen("ls -1 " .. M.DIR .. "/*.jsonl 2>/dev/null")
    if not p then return end
    for line in p:lines() do
        local stamp = line:match("(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)")
        if stamp then
            local y, mo, d, h, mi, s =
                stamp:match("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)$")
            if y then
                local t = os.time({
                    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
                })
                if t and (now - t) > max_age then os.remove(line) end
            end
        end
    end
    p:close()
end

return M
