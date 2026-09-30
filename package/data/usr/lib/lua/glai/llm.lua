--[[
  glai/llm.lua - streaming LLM client for the router.

  Runs inside the nginx request context and uses lua-resty-http (already
  present on GL firmware), so a streaming call yields to the event loop
  instead of blocking a worker.

  Three wire protocols are supported because the user supplies their own
  endpoint: OpenAI-compatible (DeepSeek, Moonshot, SiliconFlow, Ollama, ...),
  Anthropic Messages, and Google Gemini.
]]
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

local M = {}

-- ---------------------------------------------------------------------------
-- URL helpers
-- ---------------------------------------------------------------------------

local function join_url(base, path)
    if not base or base == "" then return path end
    base = base:gsub("/+$", "")
    -- a base that already names the full endpoint wins
    if base:find(path:gsub("^/", ""), 1, true) then return base end
    if base:match("/v%d+$") or base:match("/v%d+/") then
        return base .. path
    end
    return base .. path
end

local function endpoint(provider)
    local protocol = provider.protocol or "openai"
    if protocol == "anthropic" then
        return join_url(provider.base_url, "/v1/messages")
    elseif protocol == "responses" then
        return join_url(provider.base_url, "/responses")
    elseif protocol == "gemini" then
        local base = (provider.base_url ~= "" and provider.base_url)
            or "https://generativelanguage.googleapis.com"
        base = base:gsub("/+$", "")
        return base .. "/v1beta/models/" .. provider.model .. ":streamGenerateContent?alt=sse&key="
            .. provider.api_key
    end
    return join_url(provider.base_url, "/chat/completions")
end

local function headers_for(provider)
    local h = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "text/event-stream",
    }
    local protocol = provider.protocol or "openai"
    if protocol == "anthropic" then
        h["x-api-key"] = provider.api_key
        h["anthropic-version"] = "2023-06-01"
    elseif protocol ~= "gemini" then
        h["Authorization"] = "Bearer " .. provider.api_key
    end
    for k, v in pairs(provider.extra_headers or {}) do h[k] = v end
    return h
end

-- ---------------------------------------------------------------------------
-- request bodies
-- ---------------------------------------------------------------------------

local function to_openai_messages(messages)
    local out = {}
    for _, m in ipairs(messages) do
        if m.role == "tool" then
            table.insert(out, {
                role = "tool",
                tool_call_id = m.tool_call_id,
                content = m.content,
            })
        elseif m.role == "assistant" and m.tool_calls then
            table.insert(out, {
                role = "assistant",
                content = m.content or cjson.null,
                tool_calls = m.tool_calls,
            })
        else
            table.insert(out, { role = m.role, content = m.content })
        end
    end
    return out
end

local function to_anthropic_messages(messages)
    local out = {}
    for _, m in ipairs(messages) do
        if m.role == "system" then
            -- handled separately
        elseif m.role == "tool" then
            table.insert(out, {
                role = "user",
                content = {
                    { type = "tool_result", tool_use_id = m.tool_call_id, content = m.content },
                },
            })
        elseif m.role == "assistant" and m.tool_calls then
            local blocks = {}
            if m.content and m.content ~= "" then
                blocks[#blocks + 1] = { type = "text", text = m.content }
            end
            for _, tc in ipairs(m.tool_calls) do
                local args = {}
                local ok, decoded = pcall(cjson.decode, tc["function"].arguments)
                if ok and type(decoded) == "table" then args = decoded end
                blocks[#blocks + 1] = {
                    type = "tool_use",
                    id = tc.id,
                    name = tc["function"].name,
                    input = args,
                }
            end
            table.insert(out, { role = "assistant", content = blocks })
        else
            table.insert(out, { role = m.role, content = m.content })
        end
    end
    return out
end

local function build_body(provider, messages, tools, stream)
    local protocol = provider.protocol or "openai"
    local max_tokens = tonumber(provider.max_tokens) or 1024
    local temperature = tonumber(provider.temperature) or 0.2

    -- ------------------------------------------------------------------
    -- OpenAI Responses API (/v1/responses)
    --
    -- A different wire format from chat/completions: the system prompt is
    -- `instructions`, the conversation is `input`, the token cap is
    -- `max_output_tokens`, and tools use the same JSON schema shape. Gateway
    -- providers commonly expose only this endpoint, so it is a first-class
    -- protocol rather than a fallback.
    -- ------------------------------------------------------------------
    if protocol == "responses" then
        local input, instructions = {}, nil
        for _, m in ipairs(messages) do
            if m.role == "system" then
                instructions = m.content
            elseif m.role == "tool" then
                -- function_call_output is the Responses counterpart of a tool
                -- message; it keys off the call_id the model issued
                input[#input + 1] = {
                    type = "function_call_output",
                    call_id = m.tool_call_id,
                    output = m.content,
                }
            elseif m.role == "assistant" and m.tool_calls then
                if m.content and m.content ~= "" then
                    input[#input + 1] = { role = "assistant", content = m.content }
                end
                for _, tc in ipairs(m.tool_calls) do
                    input[#input + 1] = {
                        type = "function_call",
                        call_id = tc.id,
                        name = tc["function"].name,
                        arguments = tc["function"].arguments,
                    }
                end
            else
                input[#input + 1] = { role = m.role, content = m.content }
            end
        end

        local body = {
            model = provider.model,
            input = input,
            max_output_tokens = max_tokens,
        }
        if instructions then body.instructions = instructions end
        if stream then body.stream = true end
        if tools and #tools > 0 then
            local rt = {}
            for _, t in ipairs(tools) do
                rt[#rt + 1] = {
                    type = "function",
                    name = t["function"].name,
                    description = t["function"].description,
                    parameters = t["function"].parameters,
                    -- the generic schema carries this; Responses rejects it here
                    strict = false,
                }
            end
            body.tools = rt
        end
        return body
    end

    if protocol == "anthropic" then
        local system, rest = nil, {}
        for _, m in ipairs(messages) do
            if m.role == "system" then system = m.content else table.insert(rest, m) end
        end
        local body = {
            model = provider.model,
            max_tokens = max_tokens,
            temperature = temperature,
            messages = to_anthropic_messages(rest),
            stream = stream and true or false,
        }
        if system then body.system = system end
        if tools and #tools > 0 then
            local at = {}
            for _, t in ipairs(tools) do
                at[#at + 1] = {
                    name = t["function"].name,
                    description = t["function"].description,
                    input_schema = t["function"].parameters,
                }
            end
            body.tools = at
        end
        return body
    end

    if protocol == "gemini" then
        local contents, system = {}, nil
        for _, m in ipairs(messages) do
            if m.role == "system" then
                system = m.content
            elseif m.role == "tool" then
                contents[#contents + 1] = {
                    role = "user",
                    parts = { { functionResponse = { name = m.name or "tool", response = { result = m.content } } } },
                }
            elseif m.role == "assistant" then
                contents[#contents + 1] = { role = "model", parts = { { text = m.content or "" } } }
            else
                contents[#contents + 1] = { role = "user", parts = { { text = m.content or "" } } }
            end
        end
        local body = {
            contents = contents,
            generationConfig = { temperature = temperature, maxOutputTokens = max_tokens },
        }
        if tools and #tools > 0 then
            local decls = {}
            for _, t in ipairs(tools) do
                decls[#decls + 1] = {
                    name = t["function"].name,
                    description = t["function"].description,
                    parameters = t["function"].parameters,
                }
            end
            body.tools = { { functionDeclarations = decls } }
        end
        if system then
            body.systemInstruction = { parts = { { text = system } } }
        end
        return body
    end

    local body = {
        model = provider.model,
        messages = to_openai_messages(messages),
        temperature = temperature,
        max_tokens = max_tokens,
        stream = stream and true or false,
    }
    if tools and #tools > 0 then body.tools = tools end
    return body
end

-- ---------------------------------------------------------------------------
-- streaming call
-- ---------------------------------------------------------------------------

--- Normalised SSE event handler -> (text_delta, tool_call_deltas, finish_reason)
local function make_parser(protocol)
    if protocol == "responses" then
        -- OpenAI Responses API events. Text arrives as output_text.delta;
        -- function calls arrive as a function_call item followed by
        -- function_call_arguments.delta fragments that must be concatenated.
        return function(ev)
            local t = ev.type
            if t == "response.output_text.delta" then
                return ev.delta

            elseif t == "response.output_item.added" then
                local item = ev.item or {}
                if item.type == "function_call" then
                    return nil, { {
                        index = ev.output_index or 0,
                        id = item.call_id or item.id,
                        name = item.name,
                    } }
                end

            elseif t == "response.function_call_arguments.delta" then
                return nil, { {
                    index = ev.output_index or 0,
                    args_fragment = ev.delta,
                } }

            elseif t == "response.completed" then
                -- Only surface the stop reason. The completed event repeats the
                -- whole response object, including whatever system prompt the
                -- gateway injected - thousands of tokens that must not reach the
                -- event log or the next request.
                local resp = ev.response or {}
                local has_calls = false
                for _, item in ipairs(resp.output or {}) do
                    if item.type == "function_call" then has_calls = true break end
                end
                return nil, nil, has_calls and "tool_calls" or "stop"

            elseif t == "response.failed" or t == "error" then
                local err = ev.error or (ev.response or {}).error or {}
                return nil, nil, "error:" .. tostring(err.message or "request failed")
            end
            return nil
        end
    end

    if protocol == "anthropic" then
        return function(ev)
            local t = ev.type
            if t == "content_block_delta" then
                local d = ev.delta or {}
                if d.type == "text_delta" then return d.text, nil end
                if d.type == "input_json_delta" then
                    return nil, { { index = ev.index, args_fragment = d.partial_json } }
                end
            elseif t == "content_block_start" then
                local cb = ev.content_block or {}
                if cb.type == "tool_use" then
                    return nil, { { index = ev.index, id = cb.id, name = cb.name } }
                end
            elseif t == "message_delta" then
                return nil, nil, (ev.delta or {}).stop_reason
            end
            return nil
        end
    end

    -- openai + gemini
    return function(ev)
        local choices = ev.choices
        if choices and choices[1] then
            local c = choices[1]
            local delta = c.delta or {}
            local out_tools
            if delta.tool_calls then
                out_tools = {}
                for _, tc in ipairs(delta.tool_calls) do
                    out_tools[#out_tools + 1] = {
                        index = tc.index or 0,
                        id = tc.id,
                        name = tc["function"] and tc["function"].name,
                        args_fragment = tc["function"] and tc["function"].arguments,
                    }
                end
            end
            return delta.content, out_tools, c.finish_reason
        end
        -- gemini SSE shape
        local cands = ev.candidates
        if cands and cands[1] then
            local text
            for _, part in ipairs(((cands[1].content or {}).parts) or {}) do
                if part.text then text = (text or "") .. part.text end
            end
            return text, nil, cands[1].finishReason
        end
        return nil
    end
end

--- Perform a streaming chat completion.
-- @param provider table
-- @param messages table
-- @param tools    table|nil
-- @param on_event function(event) where event is
--        {type="text", text=...} | {type="tool"|"tool_args", ...} | {type="done", ...}
-- @return table|nil result, string|nil error
function M.stream(provider, messages, tools, on_event)
    local http = require "resty.http"
    local client = http.new()
    local timeout = tonumber(provider.timeout) or 60
    client:set_timeout(timeout * 1000)

    local body = cjson.encode(build_body(provider, messages, tools, true))
    local url = endpoint(provider)

    local res, err = client:request_uri(url, {
        method = "POST",
        body = body,
        headers = headers_for(provider),
        ssl_verify = provider.verify_tls ~= false,
    })
    if not res then
        return nil, "request failed: " .. tostring(err)
    end

    if res.status ~= 200 then
        local detail = res.body or ""
        -- Dump the outgoing body on rejection. Gateways usually answer with a
        -- bare "invalid request", so the only way to find the offending field is
        -- to see exactly what was sent. Written to a file because the nginx log
        -- truncates long lines. The Authorization header is never included.
        local f = io.open("/tmp/gl-ai-agent/last-request.json", "w")
        if f then
            f:write(body)
            f:close()
        end
        ngx.log(ngx.ERR, "gl_ai llm HTTP ", res.status, " url=", url,
            " bodyBytes=", #body, " body=", body:sub(1, 300))
        if #detail > 400 then detail = detail:sub(1, 400) .. "..." end
        return nil, "HTTP " .. tostring(res.status) .. ": " .. detail
    end

    local parse = make_parser(provider.protocol or "openai")
    local text = ""
    local calls = {}       -- index -> {id, name, args}
    local finish = nil
    local usage = nil

    local reader = res.body_reader
    if not reader then
        return nil, "streaming unsupported by this nginx build"
    end

    local buffer = ""
    while true do
        local chunk, rerr = reader()
        if rerr then return nil, "stream read error: " .. tostring(rerr) end
        if not chunk then break end
        buffer = buffer .. chunk

        while true do
            local nl = buffer:find("\n", 1, true)
            if not nl then break end
            local line = buffer:sub(1, nl - 1)
            buffer = buffer:sub(nl + 1)
            line = line:gsub("\r$", "")

            if line:sub(1, 5) == "data:" then
                local payload = line:sub(6):gsub("^%s+", "")
                if payload ~= "[DONE]" and payload ~= "" then
                    local ok, ev = pcall(cjson.decode, payload)
                    if ok and type(ev) == "table" then
                        if ev.usage then usage = ev.usage end
                        local dtext, dtools, dfinish = parse(ev)
                        if dtext and dtext ~= "" then
                            text = text .. dtext
                            if on_event then on_event({ type = "text", text = dtext }) end
                        end
                        if dtools then
                            for _, tc in ipairs(dtools) do
                                local idx = tc.index or 0
                                calls[idx] = calls[idx] or { args = "" }
                                local slot = calls[idx]
                                if tc.id then slot.id = tc.id end
                                if tc.name and tc.name ~= "" then
                                    slot.name = (slot.name or "") .. tc.name
                                    if on_event then
                                        on_event({ type = "tool_start", index = idx, name = slot.name })
                                    end
                                end
                                if tc.args_fragment then
                                    slot.args = slot.args .. tc.args_fragment
                                    if on_event then
                                        on_event({
                                            type = "tool_args",
                                            index = idx,
                                            name = slot.name,
                                            fragment = tc.args_fragment,
                                        })
                                    end
                                end
                            end
                        end
                        if dfinish and dfinish ~= "" then finish = dfinish end
                    end
                end
            end
        end
    end

    -- normalise accumulated tool calls into OpenAI shape
    local tool_calls = {}
    local indexes = {}
    for idx in pairs(calls) do indexes[#indexes + 1] = idx end
    table.sort(indexes)
    for _, idx in ipairs(indexes) do
        local c = calls[idx]
        if c.name then
            tool_calls[#tool_calls + 1] = {
                id = c.id or ("call_" .. tostring(idx)),
                type = "function",
                ["function"] = { name = c.name, arguments = (c.args ~= "" and c.args) or "{}" },
            }
        end
    end

    return {
        text = text,
        tool_calls = (#tool_calls > 0) and tool_calls or nil,
        finish_reason = finish,
        usage = usage,
    }
end

--- Non-streaming completion.
--
-- Used when provider.stream is false (the default). One request, one response,
-- no long-lived read - which matters because a turn runs inside an ngx.timer.
-- Returns the same normalised shape as M.stream so the agent loop is identical
-- either way.
function M.complete(provider, messages, tools)
    local http = require "resty.http"
    local client = http.new()
    client:set_timeout((tonumber(provider.timeout) or 60) * 1000)

    local body = cjson.encode(build_body(provider, messages, tools, false))
    local url = endpoint(provider)

    local res, err = client:request_uri(url, {
        method = "POST",
        body = body,
        headers = headers_for(provider),
        ssl_verify = provider.verify_tls ~= false,
    })
    if not res then
        return nil, "request failed: " .. tostring(err)
    end
    if res.status ~= 200 then
        local detail = res.body or ""
        local f = io.open("/tmp/gl-ai-agent/last-request.json", "w")
        if f then f:write(body) f:close() end
        ngx.log(ngx.ERR, "gl_ai llm HTTP ", res.status, " url=", url, " bodyBytes=", #body,
            " body=", body:sub(1, 300))
        if #detail > 400 then detail = detail:sub(1, 400) .. "..." end
        return nil, "HTTP " .. tostring(res.status) .. ": " .. detail
    end

    local ok, decoded = pcall(cjson.decode, res.body)
    if not ok or type(decoded) ~= "table" then
        return nil, "unexpected response body"
    end

    local text, tool_calls, finish = "", nil, nil
    local protocol = provider.protocol or "openai"

    if protocol == "responses" then
        for _, item in ipairs(decoded.output or {}) do
            if item.type == "function_call" then
                tool_calls = tool_calls or {}
                tool_calls[#tool_calls + 1] = {
                    id = item.call_id or item.id,
                    type = "function",
                    ["function"] = {
                        name = item.name,
                        arguments = item.arguments or "{}",
                    },
                }
            else
                for _, b in ipairs(item.content or {}) do
                    if b.type == "output_text" and b.text then text = text .. b.text end
                end
            end
        end
        finish = tool_calls and "tool_calls" or "stop"

    elseif protocol == "anthropic" then
        for _, b in ipairs(decoded.content or {}) do
            if b.type == "text" then
                text = text .. (b.text or "")
            elseif b.type == "tool_use" then
                tool_calls = tool_calls or {}
                tool_calls[#tool_calls + 1] = {
                    id = b.id,
                    type = "function",
                    ["function"] = {
                        name = b.name,
                        arguments = cjson.encode(b.input or {}),
                    },
                }
            end
        end
        finish = decoded.stop_reason

    else
        local choice = (decoded.choices or {})[1] or {}
        local msg = choice.message or {}
        text = msg.content or ""
        if msg.tool_calls then
            for _, tc in ipairs(msg.tool_calls) do
                tool_calls = tool_calls or {}
                tool_calls[#tool_calls + 1] = {
                    id = tc.id,
                    type = "function",
                    ["function"] = {
                        name = (tc["function"] or {}).name,
                        arguments = (tc["function"] or {}).arguments or "{}",
                    },
                }
            end
        end
        finish = choice.finish_reason
    end

    return {
        text = text,
        tool_calls = tool_calls,
        finish_reason = finish,
        usage = decoded.usage,
    }
end

--- Non-streaming probe used by the "test connection" button.
function M.test(provider)
    local http = require "resty.http"
    local client = http.new()
    client:set_timeout((tonumber(provider.timeout) or 30) * 1000)
    local body = cjson.encode(build_body(provider, {
        { role = "user", content = "Reply with exactly: OK" },
    }, nil, false))
    local started = ngx.now()
    local res, err = client:request_uri(endpoint(provider), {
        method = "POST",
        body = body,
        headers = headers_for(provider),
        ssl_verify = provider.verify_tls ~= false,
    })
    local elapsed = ngx.now() - started
    if not res then return nil, "request failed: " .. tostring(err) end
    if res.status ~= 200 then
        local detail = res.body or ""
        if #detail > 300 then detail = detail:sub(1, 300) .. "..." end
        return nil, "HTTP " .. tostring(res.status) .. ": " .. detail
    end
    local ok, decoded = pcall(cjson.decode, res.body)
    if not ok then return nil, "unexpected response body" end

    local text = ""
    if decoded.choices and decoded.choices[1] then
        -- chat/completions
        text = ((decoded.choices[1].message or {}).content) or ""
    elseif decoded.output then
        -- Responses API: output[] holds message items whose content[] is the text
        for _, item in ipairs(decoded.output) do
            for _, b in ipairs(item.content or {}) do
                if b.type == "output_text" and b.text then text = text .. b.text end
            end
        end
    elseif decoded.content then
        -- Anthropic messages
        for _, b in ipairs(decoded.content) do
            if b.type == "text" then text = text .. (b.text or "") end
        end
    elseif decoded.candidates and decoded.candidates[1] then
        -- Gemini
        for _, part in ipairs((((decoded.candidates[1].content or {}).parts) or {})) do
            if part.text then text = text .. part.text end
        end
    end
    return { ok = true, latency_ms = math.floor(elapsed * 1000), reply = text:sub(1, 120) }
end

M.endpoint = endpoint
return M
