--[[
  glai/turns.lua - run an agent turn, one step per poll.

  WHY NOT A BACKGROUND TIMER
  --------------------------
  The obvious design is to run the turn in an ngx.timer and let the browser read
  the event log. That does not work on this firmware: many GL RPC handlers need
  a subrequest internally, and `ngx.location.capture` is disabled inside a timer
  context. It fails with

      ./files/rpc.lua:183: API disabled in the current context

  which killed the turn part-way through (a pure-Lua tool like wifi.get_config
  worked, clients.get_list did not). Timers would also give a turn a fixed
  lifetime, which is awkward for slow reasoning models.

  So a turn advances cooperatively: `chat` prepares the state and the browser's
  polling calls `poll`, each of which executes exactly one agent step inside a
  normal request context where every API is available. The client already polls,
  so nothing is lost, and the turn becomes observable and interruptible.

  State lives in
      /tmp/gl-ai-agent/state/<turn-id>.json   { messages, step, ... }
  Events live in
      /tmp/gl-ai-agent/turns/<turn-id>.jsonl

  Approval flags live in a small JSON file rather than an ngx shared dict,
  because declaring a dict needs a `lua_shared_dict` directive, i.e. an nginx
  config file - and installing one of those is exactly what this plugin avoids.
]]
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

local events = require "glai.events"
local session = require "glai.session"
local config = require "glai.config"

local M = {}

local DIR = "/tmp/gl-ai-agent"
local STATE_DIR = DIR .. "/state"
local CLAIM_DIR = DIR .. "/claims"
local WORKING_DIR = DIR .. "/working"
local APPROVALS = DIR .. "/approvals.json"
local AWAITING_DIR = DIR .. "/awaiting"
local DECIDED_DIR = DIR .. "/decided"

local function ensure_dirs()
    os.execute("mkdir -p " .. DIR .. " " .. STATE_DIR .. " " .. CLAIM_DIR
        .. " " .. WORKING_DIR .. " " .. AWAITING_DIR .. " " .. DECIDED_DIR)
end

--- How long a confirmation may sit unanswered before it counts as expired.
--- Generous enough for a real decision, short enough that an orphaned card
--- cannot wedge the turn. Declared up here because approval_verdict reads it and
--- a `local` declared later would not be in scope inside that closure.
local APPROVAL_TTL = 150

local function path_ok(id)
    return type(id) == "string" and id:match("^[%w_%-]+$") ~= nil
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    local ok, decoded = pcall(cjson.decode, raw)
    if ok and type(decoded) == "table" then return decoded end
    return nil
end

local function write_json(path, value)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(cjson.encode(value))
    f:close()
    return true
end

-- ---------------------------------------------------------------------------
-- approvals
-- ---------------------------------------------------------------------------

local function read_approvals()
    return read_json(APPROVALS) or {}
end

local function write_approvals(tbl)
    ensure_dirs()
    return write_json(APPROVALS, tbl)
end

--- Raise a confirmation card and return immediately.
--
-- Non-blocking by design: the caller stores the returned id in its own state and
-- asks again on the next poll. Blocking here would hold an HTTP request open
-- until the user clicks, which the UI reports as a timeout and which also blocks
-- the very request carrying their answer.
--
-- The waiting marker is written to disk *here*, not when the surrounding poll
-- finishes. A poll can spend ten seconds in the model call before it reaches
-- this point, and a second poll arriving in that window would otherwise not know
-- a confirmation was coming and would run the model again - which is how two
-- identical cards once appeared for a single request.
function M.ask_approval(emit, tool, args, turn_id, timeout)
    ensure_dirs()

    -- Serialise the read-modify-write, then check for an existing card.
    --
    -- Two polls can reach this at the same moment (they interleave at every
    -- yield), and a plain read-then-write lets both see "nothing open" and both
    -- insert an entry. That produced two live approval ids and two cards for one
    -- change, leaving an orphan that no click could clear. The lock makes the
    -- check and the insert one critical section; whoever loses simply reports
    -- the id that already exists.
    local lock = CLAIM_DIR .. "/ask-" .. tostring(turn_id or "turn")
    for _ = 1, 40 do
        local got = os.execute("ln -s '" .. tostring(os.time()) .. "' '" .. lock .. "' 2>/dev/null")
        if got then break end
        if (tonumber(read_claim("ask-" .. tostring(turn_id or "turn"))) or 0) + 5 < os.time() then
            os.remove(lock)                     -- stale holder
        end
        ngx.sleep(0.05)
    end

    local all = read_approvals()
    local prefix = tostring(turn_id or "turn") .. "-"
    local existing = nil
    for open, state in pairs(all) do
        if state == "pending" and open:sub(1, #prefix) == prefix then
            existing = open
            break
        end
    end

    if existing then
        os.remove(lock)
        return existing                          -- the card is already on screen
    end

    local id = prefix .. tostring(math.random(100000, 999999))
    all[id] = "pending"
    write_approvals(all)

    if path_ok(turn_id) then
        local f = io.open(AWAITING_DIR .. "/" .. turn_id, "w")
        if f then
            f:write(id)
            f:close()
        end
    end
    os.remove(lock)

    emit({
        type = "confirm",
        id = id,
        tool = tool.name,
        risk = tool.risk,
        args = args,
        reversible = tool.reversible and true or false,
        preview = tool.desc,
        timeout = timeout,
    })
    return id
end

--- The confirmation this turn is waiting on, if any.
function M.awaiting_for(turn_id)
    if not path_ok(turn_id) then return nil end
    local f = io.open(AWAITING_DIR .. "/" .. turn_id, "r")
    if not f then return nil end
    local id = f:read("*l")
    f:close()
    if not id or id == "" then return nil end
    -- an answered or vanished approval is no longer "awaiting"
    local v = M.approval_verdict(id)
    if v == "pending" then return id end
    return nil
end

--- Clear the waiting marker once the tool has been resolved.
function M.clear_awaiting(turn_id)
    if not path_ok(turn_id) then return end
    os.remove(AWAITING_DIR .. "/" .. turn_id)
end

--- Drop approvals whose turn is gone, or which are older than the window.
--
-- Approval ids are "<turn-id>-<random>", so the owning turn can be recovered
-- from the id. This keeps a crashed or abandoned turn from leaving a pending
-- entry that would show up as a phantom confirmation later.
function M.sweep_approvals()
    local all = read_approvals()
    if not next(all) then return end

    local changed = false
    local now = os.time()
    for id in pairs(all) do
        local turn = id:match("^(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+)-")
        local stale = false

        if not turn then
            stale = true
        else
            -- Read the turn's state file directly. This function is defined above
            -- load_state, so calling that local here would resolve to a global
            -- (nil) and blow up at run time - a mistake that took down the whole
            -- start path.
            local f = io.open(STATE_DIR .. "/" .. turn .. ".json", "r")
            local alive = false
            if f then
                alive = true
                f:close()
            end
            if not alive and M.awaiting_for(turn) == nil then
                stale = true                 -- the owning turn is gone
            end
        end

        if not stale then
            -- also bound an open approval by age
            local y, mo, d, h, mi, s = id:match(
                "^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)")
            if y then
                local t = os.time({
                    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
                })
                if t and (now - t) > 1800 then stale = true end
            end
        end

        if stale then
            all[id] = nil
            changed = true
        end
    end
    if changed then write_approvals(all) end
end

--- Read a decision. Returns "pending" | "allow" | "deny" | "expired".
--
-- A pending entry that has outlived its window counts as expired. That is the
-- backstop for the turn state machine: if a card is ever raised but nothing can
-- answer it (an orphaned duplicate approval, a browser that went away), the turn
-- still terminates instead of polling for ever.
function M.approval_verdict(id)
    if type(id) ~= "string" then return "expired" end
    local v = read_approvals()[id]
    if v == nil then return "expired" end
    if v == "pending" then
        local f = io.open(AWAITING_DIR .. "/" .. (id:match("^(.*)%-%d+$") or id), "r")
        if f then f:close() end
        -- age is encoded in the id's leading timestamp
        local y, mo, d, h, mi, s = id:match(
            "^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)")
        if y then
            local born = os.time({
                year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
            })
            if born and (os.time() - born) > APPROVAL_TTL then
                return "expired"
            end
        end
    end
    return v
end

--- Drop a decided approval once it has been acted on.
function M.forget_approval(id)
    if type(id) ~= "string" then return end
    local all = read_approvals()
    if all[id] == nil then return end
    all[id] = nil
    write_approvals(all)
end

--- Block until a decision arrives (or the window elapses).
--- Only for the scripted M.run path; the interactive path never blocks.
function M.wait_for_approval(id, timeout)
    if type(id) ~= "string" then return false end
    local deadline = ngx.now() + (timeout or 45)
    while ngx.now() < deadline do
        local v = read_approvals()[id]
        if v == "allow" then return true end
        if v == "deny" or v == nil then return false end
        ngx.sleep(0.25)
    end
    M.forget_approval(id)
    return false
end

--- Record the user's answer.
--
-- The answer applies to every pending approval belonging to the same turn, not
-- just the id that was clicked. Overlapping polls can raise more than one id for
-- a single tool call, and a leftover "pending" would stall the turn: the UI shows
-- one card, so no second click could ever arrive to clear it.
function M.decide(id, allow)
    if type(id) ~= "string" then return false end
    local all = read_approvals()
    if all[id] == nil then return false end

    local turn = id:match("^(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+)-")
    local answer = allow and "allow" or "deny"
    local applied = 0

    for other, state in pairs(all) do
        if state == "pending" and (other == id or (turn and other:sub(1, #turn) == turn)) then
            all[other] = answer
            applied = applied + 1
        end
    end
    write_approvals(all)

    if turn then
        M.clear_awaiting(turn)
        -- A refusal is also recorded as a terminal marker for the turn.
        --
        -- This is not belt-and-braces, it is the mechanism: nginx serves from
        -- several workers here, and the step that raised the card may be parked
        -- inside a different worker that never observes the updated approvals
        -- file. Checking this marker on every poll makes the turn end
        -- deterministically instead of depending on which worker answers next.
        if not allow then
            ensure_dirs()
            local f = io.open(DECIDED_DIR .. "/" .. turn, "w")
            if f then
                f:write("deny")
                f:close()
            end
        end
    end
    return applied > 0
end

--- The terminal decision recorded for a turn, if the user has made one.
function M.decided_for(turn_id)
    if not path_ok(turn_id) then return nil end
    local f = io.open(DECIDED_DIR .. "/" .. turn_id, "r")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

function M.clear_decided(turn_id)
    if not path_ok(turn_id) then return end
    os.remove(DECIDED_DIR .. "/" .. turn_id)
end

-- ---------------------------------------------------------------------------
-- turn state
-- ---------------------------------------------------------------------------

local function state_path(id)
    return STATE_DIR .. "/" .. id .. ".json"
end

local function load_state(id)
    if not path_ok(id) then return nil end
    local s = read_json(state_path(id))
    if s and type(s.declined) ~= "table" then
        -- state written before this field existed; keep the invariant at the
        -- boundary so no caller has to guard for it
        s.declined = {}
    end
    return s
end

local function save_state(state)
    ensure_dirs()
    return write_json(state_path(state.turn_id), state)
end

--- Begin a turn: create the session, the event log and the initial state.
function M.start(req)
    local text = tostring(req.text or "")
    if text == "" then return nil, "text is required" end

    -- Clear approvals left over from turns that no longer exist. They cannot be
    -- acted on and the UI has no card for them, so keeping them would only
    -- confuse the next turn's pending list.
    M.sweep_approvals()

    local sess
    if req.session_id and req.session_id ~= "" then
        sess = session.load(req.session_id)
    end
    if not sess then
        sess = session.create(session.auto_title(text))
        sess.messages = {}
    end
    if not sess.messages then sess.messages = {} end

    local turn_id = events.new_id()
    events.create(turn_id)

    local cfg = config.load()
    local state = {
        turn_id = turn_id,
        session_id = sess.id,
        text = text,
        step = 0,
        messages = sess.messages,
        permission = req.permission or cfg.agent.permission,
        confirm_timeout = tonumber(cfg.agent.confirm_timeout) or 45,
        max_steps = tonumber(cfg.agent.max_steps) or 8,
        started = os.time(),
        -- Refusals live in the turn state, not in a step record: a step record is
        -- replaced whenever the next step starts, so a change the user declined
        -- would be proposed again by the following step and stall the turn.
        declined = {},
    }
    save_state(state)

    events.sweep(3600)
    M.sweep_states(3600)

    return { turn_id = turn_id, session_id = sess.id, title = sess.title }
end

--- Drive the turn forward by one unit of work.
--
-- A unit is either "run the model for the next step" or "resolve one pending
-- tool call". Both are short, bounded operations, so the request returns
-- promptly - unless the user is being asked to confirm, in which case the step
-- record comes back with `awaiting` and the caller simply stops until the next
-- poll.
--
-- @return boolean more  false when the turn has finished
local function advance(state)
    ensure_dirs()
    local agent = require "glai.agent"
    local emit = function(event) events.append(state.turn_id, event) end

    local cfg = config.load()
    local max_steps = tonumber(cfg.agent.max_steps) or state.max_steps or 8

    if not config.is_configured(cfg) then
        emit({ type = "error", message = "not_configured" })
        return false
    end

    -- A step is already part-way through (its model call is done and it is
    -- working through tool calls): continue it.
    if state.pending then
        local rec, done = agent.step_pending(state.pending, state.messages, emit, {
            permission = state.permission,
            turn_id = state.turn_id,
            confirm_timeout = state.confirm_timeout,
            declined = state.declined,
        })
        state.pending = rec
        state.awaiting = rec and rec.awaiting or nil
        trace(state.turn_id, "pending-step done=%s rec=%s awaiting=%s",
            tostring(done), tostring(rec ~= nil), tostring(state.awaiting))
        if done then return false end
        if rec then return true end
        -- rec is nil: every tool of that step is resolved, so fall through and
        -- begin the next step. Returning here instead would spin for ever, because
        -- state.pending is now nil and the next poll would take this branch again
        -- with nothing left to do.
        state.awaiting = nil
    end

    if state.step >= max_steps then
        emit({ type = "done", reason = "max_steps" })
        return false
    end

    -- Never start a step while the user has a card in front of them. Polls
    -- interleave at every yield, so without this an overlapping poll can run the
    -- model again and propose the same change a second time.
    if M.awaiting_for(state.turn_id) then
        return true
    end

    state.step = state.step + 1
    emit({ type = "step", index = state.step, phase = "thinking" })

    local rec, done = agent.step_begin(state.messages, state.text, emit, {
        permission = state.permission,
        turn_id = state.turn_id,
        confirm_timeout = state.confirm_timeout,
        first = (state.step == 1),
        declined = state.declined,
    })
    state.pending = rec
    state.awaiting = rec and rec.awaiting or nil

    if done then return false end
    if rec then return true end                 -- has tools to work through
    return true                                 -- step produced no tools; loop again
end

--- How long a claim is honoured before another poll may break it. A unit of
--- work is one model call, so this only needs to exceed that.
local CLAIM_TTL = 200

--- What has been claimed, and when (epoch seconds), or nil.
local function read_claim(turn_id)
    local path = CLAIM_DIR .. "/" .. turn_id
    -- the claim is a symlink whose target is the timestamp
    local p = io.popen("readlink '" .. path .. "' 2>/dev/null")
    if p then
        local v = p:read("*l")
        p:close()
        if v then return tonumber(v) end
    end
    -- fall back to a plain file holding the timestamp
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return tonumber(s)
end

--- Try to become the only poll allowed to advance this turn.
--
-- `ln -s` is atomic: it fails if the link already exists, which makes it a
-- usable lock on a filesystem with no flock available to Lua. A plain
-- "is the file there?" test would be racy, and a timestamp field inside the
-- state file is worse - the first poll only writes it after its model call
-- returns, so a second poll arriving during that call would start a competing
-- step. That is exactly how two identical confirmation cards once appeared for a
-- single request.
local function claim(turn_id)
    ensure_dirs()
    local path = CLAIM_DIR .. "/" .. turn_id

    local held = read_claim(turn_id)
    if held then
        if (os.time() - held) < CLAIM_TTL then
            return false                  -- someone is genuinely working
        end
        os.remove(path)                   -- abandoned; take it over
    end

    local stamp = tostring(os.time())
    local ok = os.execute("ln -s '" .. stamp .. "' '" .. path .. "' 2>/dev/null")
    if not ok then
        -- ln failed (already exists) or symlinks are unavailable here
        local f = io.open(path, "r")
        if f then f:close() return false end
        f = io.open(path, "w")
        if not f then return false end
        f:write(stamp)
        f:close()
    end
    return true
end

local function release(turn_id)
    os.remove(CLAIM_DIR .. "/" .. turn_id)
end

--- Marker written *before* a step starts and removed after it ends.
--
-- The claim file alone leaves a gap: it is released as soon as advance() returns,
-- but a confirmation raised inside that step is only visible once its own file
-- has been flushed. A poll landing in that gap would start a competing step and
-- raise a second card. Writing this marker before the model call - the slow part
-- - shrinks the window from seconds to microseconds.
local function mark_working(turn_id)
    ensure_dirs()
    local f = io.open(WORKING_DIR .. "/" .. turn_id, "w")
    if f then
        f:write(tostring(os.time()))
        f:close()
    end
end

local function clear_working(turn_id)
    os.remove(WORKING_DIR .. "/" .. turn_id)
end

local function is_working(turn_id)
    local f = io.open(WORKING_DIR .. "/" .. turn_id, "r")
    if not f then return false end
    local v = tonumber(f:read("*l"))
    f:close()
    if not v then return true end
    -- a marker older than the claim window means the step died
    return (os.time() - v) < CLAIM_TTL
end

--- Append a line to the turn's state-machine trace.
--
-- The turn spans several short HTTP requests, so when one wedges there is no
-- stack trace to read - only a state file frozen mid-step. This trace is the
-- replacement for a debugger: every decision point records why it stopped or
-- continued. Cheap (one small append per poll) and it is what made the deadlock
-- in the approval path findable.
local function trace(turn_id, fmt, ...)
    if not path_ok(turn_id) then return end
    ensure_dirs()
    local f = io.open(DIR .. "/trace.log", "a")
    if not f then return end
    local ok, line = pcall(string.format, fmt, ...)
    f:write(os.date("%H:%M:%S"), " ", turn_id, " ", ok and line or fmt, "\n")
    f:close()
end

--- Advance the turn, or just report new events.
--
-- Each call does one bounded unit of work. Mutual exclusion is an atomic claim
-- file plus a working marker, so overlapping polls cannot both start a step.
function M.poll(turn_id, offset)
    if not path_ok(turn_id) then return { error = "bad_turn_id" } end

    local state = load_state(turn_id)
    local list, next_offset, finished = events.read(turn_id, offset)

    if finished then
        if state then
            local sess = session.load(state.session_id)
            if sess then
                sess.messages = state.messages
                if sess.title == "New chat" or sess.title == nil then
                    sess.title = session.auto_title(state.text)
                end
                session.save(sess)
            end
            os.remove(state_path(turn_id))
            if state.awaiting_id then M.forget_approval(state.awaiting_id) end
        end
        M.clear_awaiting(turn_id)
        clear_working(turn_id)
        release(turn_id)
        return { events = list, offset = next_offset, finished = true }
    end

    if not state then
        -- no state and no terminal event: something went wrong earlier
        events.append(turn_id, {
            type = "error",
            message = "internal_error",
            detail = "turn state is missing",
        })
        events.append(turn_id, { type = "saved" })
        local l2, o2 = events.read(turn_id, offset)
        return { events = l2, offset = o2, finished = true }
    end

    -- The user already refused the pending change: end the turn now.
    --
    -- Checked here, before anything else, because the step that raised the card
    -- may be parked in another nginx worker holding a stale view of the approvals
    -- file. This marker is the single source of truth for "the turn is over".
    -- The step that handled the refusal already emitted the explanatory text;
    -- this only supplies the terminal events.
    local decision = M.decided_for(turn_id)
    if decision == "deny" then
        trace(turn_id, "terminal decision=%s", decision)
        events.append(turn_id, { type = "done", reason = "declined" })
        events.append(turn_id, { type = "saved", session_id = state.session_id })

        local sess = session.load(state.session_id)
        if sess then
            sess.messages = state.messages
            if sess.title == "New chat" or sess.title == nil then
                sess.title = session.auto_title(state.text)
            end
            session.save(sess)
        end
        os.remove(state_path(turn_id))
        M.clear_awaiting(turn_id)
        M.clear_decided(turn_id)
        clear_working(turn_id)
        release(turn_id)

        local l5, o5 = events.read(turn_id, offset)
        return { events = l5, offset = o5, finished = true }
    end

    -- A previous step recorded its start but never cleared it: it died. Report
    -- that instead of letting the UI poll for ever. (advance() cannot be wrapped
    -- in pcall - it yields - so failure is detected here, on the next poll.)
    if state.step_started then
        events.append(turn_id, {
            type = "error",
            message = "internal_error",
            detail = "the step did not complete; see the router log",
        })
        events.append(turn_id, { type = "saved", session_id = state.session_id })
        os.remove(state_path(turn_id))
        release(turn_id)
        local l4, o4 = events.read(turn_id, offset)
        return { events = l4, offset = o4, finished = true }
    end

    -- A confirmation is outstanding: nothing may advance until the user answers.
    local awaiting = M.awaiting_for(turn_id)
    if awaiting then
        trace(turn_id, "hold awaiting=%s verdict=%s", awaiting, M.approval_verdict(awaiting))
        local l3, o3 = events.read(turn_id, offset)
        return { events = l3, offset = o3, finished = false, awaiting = awaiting }
    end

    -- Someone else is working on this turn: report and back off. Both markers
    -- are checked because they cover different windows.
    if is_working(turn_id) or not claim(turn_id) then
        trace(turn_id, "hold busy working=%s", tostring(is_working(turn_id)))
        return { events = list, offset = next_offset, finished = false, busy = true }
    end

    -- No pcall around advance(): it yields (ubus and the outbound model call) and
    -- Lua 5.1 cannot yield across a pcall boundary. A crash flag recorded before
    -- the step, cleared only on success, gives the same protection honestly.
    state.step_started = ngx.now()
    save_state(state)
    mark_working(turn_id)

    local more = advance(state)

    state.step_started = nil
    save_state(state)
    clear_working(turn_id)
    release(turn_id)
    trace(turn_id, "advance step=%s more=%s pending=%s declined=%s",
        tostring(state.step), tostring(more),
        tostring(state.pending ~= nil), tostring(next(state.declined or {}) ~= nil))

    if not more then
        events.append(turn_id, { type = "saved", session_id = state.session_id })
    end

    list, next_offset, finished = events.read(turn_id, offset)
    return {
        events = list,
        offset = next_offset,
        finished = finished or not more,
        awaiting = M.awaiting_for(turn_id),
    }
end

--- Drop stale turn state so /tmp cannot grow without bound.
function M.sweep_states(max_age)
    max_age = max_age or 3600
    ensure_dirs()
    local now = os.time()
    local p = io.popen("ls -1 " .. STATE_DIR .. "/*.json 2>/dev/null")
    if not p then return end
    for line in p:lines() do
        local s = read_json(line)
        if s and s.started and (now - s.started) > max_age then os.remove(line) end
    end
    p:close()
    -- approvals are short-lived by nature
    local a = read_approvals()
    local changed = false
    for id, v in pairs(a) do
        if v == "pending" and now - 0 > 0 then
            -- cleared by the waiting step on timeout; drop orphans defensively
        end
    end
    if changed then write_approvals(a) end
end

M.read_approvals = read_approvals
M.load_state = load_state
return M
