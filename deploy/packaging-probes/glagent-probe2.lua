-- Probe 2: streaming (SSE) capability + ubus reachability
local ok, err = pcall(function()
    ngx.header["Content-Type"] = "text/event-stream"
    ngx.header["Cache-Control"] = "no-cache"

    ngx.say("event: hello")
    ngx.say('data: {"n":0}')
    ngx.say("")

    for i = 1, 3 do
        ngx.say("event: tick")
        ngx.say('data: {"n":' .. i .. '}')
        ngx.say("")
        ngx.flush(true)
    end

    -- can we talk to ubus from inside nginx?
    local ubus_ok = pcall(require, "ubus")
    local rpc_ok = pcall(require, "oui.rpc")
    local http_ok = pcall(require, "resty.http")
    local socket_ok = ngx.socket ~= nil and ngx.socket.tcp ~= nil

    ngx.say("event: caps")
    ngx.say('data: {"ubus":' .. tostring(ubus_ok)
        .. ',"oui_rpc":' .. tostring(rpc_ok)
        .. ',"resty_http":' .. tostring(http_ok)
        .. ',"ngx_socket":' .. tostring(socket_ok) .. '}')
    ngx.say("")

    ngx.say("event: done")
    ngx.say('data: {"ok":true}')
    ngx.say("")
end)
if not ok then
    ngx.say("event: error")
    ngx.say('data: {"err":"' .. tostring(err):gsub('"', "'") .. '"}')
    ngx.say("")
end
