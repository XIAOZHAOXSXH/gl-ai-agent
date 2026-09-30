local ok, err = pcall(function()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local bfile = ngx.req.get_body_file()
    if not body and bfile then
        local f = io.open(bfile, "r")
        if f then body = f:read("*a"); f:close() end
    end
    local cjson = require "cjson"
    local dec = "nil"
    if body then
        local o, e = pcall(cjson.decode, body)
        dec = o and cjson.encode(o) or ("ERR:" .. tostring(e))
    end
    local hdr = ngx.req.get_headers()
    ngx.say("PROBE_OK")
    ngx.say("method=" .. ngx.req.get_method())
    ngx.say("len=" .. (body and #body or -1))
    ngx.say("body=[" .. tostring(body) .. "]")
    ngx.say("decode=" .. tostring(dec))
    ngx.say("glinet=" .. tostring(hdr["glinet"]))
end)
if not ok then ngx.say("PROBE_FAIL: " .. tostring(err)) end
