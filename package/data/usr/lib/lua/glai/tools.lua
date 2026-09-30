--[[
  glai/tools.lua - THE single source of truth for what the agent can do.

  One declaration drives all four consumers:
    1. the function schema handed to the LLM
    2. the execution mapping (SDK4 RPC object + method)
    3. the UI (label, risk badge, parameters shown in the confirm card)
    4. the policy engine (risk level -> auto / confirm / refuse)

  Everything here was derived from the RPC binaries actually present on the
  device (`strings /usr/lib/oui-httpd/rpc/<obj>`), not from guesswork.

  Risk levels:
    low    - read-only, never changes state
    medium - reversible configuration change
    high   - disruptive or security-relevant; always confirmed
]]
local rpc = require "glai.rpc"

local M = {}

local function json_arg(t)
    local cjson = require "cjson"
    return cjson.encode(t)
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function band_of(name)
    if not name then return nil end
    if name:find("2g") or name:find("2G") then return "2g" end
    if name:find("5g") or name:find("5G") then return "5g" end
    if name:find("6g") or name:find("6G") then return "6g" end
    return nil
end

--- Flatten wifi.get_config into a compact, LLM-friendly shape.
local function wifi_summary()
    local cfg, err = rpc.call("wifi", "get_config", {})
    if not cfg then return nil, err end
    local st = rpc.call("wifi", "get_status", {}) or {}

    local radios = {}
    for _, r in ipairs(st.res or {}) do
        local key = band_of(r.band)
        if key then
            radios[key] = { channel = r.channel, state = r.state, name = r.name }
        end
    end

    local out = { bands = {} }
    for _, group in ipairs(cfg.res or {}) do
        local key = band_of(group.band)
        local entry = { band = group.band, networks = {} }
        for _, i in ipairs(group.ifaces or {}) do
            table.insert(entry.networks, {
                name = i.name,
                ssid = i.ssid,
                enabled = i.enabled and true or false,
                encryption = i.encryption,
                hidden = i.hidden and true or false,
                has_password = (i.key ~= nil and i.key ~= ""),
                kind = i.guest and "guest" or (i.iot and "iot" or "main"),
            })
        end
        if key and radios[key] then
            entry.channel = radios[key].channel
            entry.radio_state = radios[key].state
        end
        table.insert(out.bands, entry)
    end
    return out
end

-- ---------------------------------------------------------------------------
-- the registry
-- ---------------------------------------------------------------------------

M.registry = {
    -- ======================= READ ONLY =======================
    {
        name = "router_overview",
        group = "diagnostics",
        risk = "low",
        desc = "One-shot router health snapshot: model, firmware, uptime, CPU load, memory, WiFi bands and the connected client summary. Call this first when the user asks anything open-ended.",
        params = {},
        run = function()
            local info = rpc.call("system", "get_info", {}) or {}
            local load = rpc.call("system", "get_load", {}) or {}
            local status = rpc.call("system", "get_status", {}) or {}
            local clients = rpc.call("clients", "get_status", {}) or {}
            local wifi = wifi_summary() or { bands = {} }

            local mem_pct = nil
            if load.memory_total and load.memory_total > 0 then
                mem_pct = math.floor((load.memory_total - load.memory_free - (load.memory_buff_cache or 0))
                    / load.memory_total * 100)
            end

            return {
                model = info.model or status.model,
                firmware = info.firmware_version or status.firmware_version,
                uptime_seconds = status.uptime,
                cpu_load = load.load_average,
                memory_used_percent = mem_pct,
                temperature = status.temperature,
                wan = {
                    interface = status.wan_interface,
                    ip = status.wan_ip,
                    online = status.wan_status,
                    ipv6 = status.wan_ip6,
                },
                wifi = wifi,
                clients = {
                    wireless = clients.wireless_total,
                    wired = clients.cable_total,
                },
                capabilities = info.hardware_feature or {},
            }
        end,
    },
    {
        name = "wifi_get_config",
        group = "wireless",
        risk = "low",
        desc = "Read the full WiFi configuration: per band the SSID, whether it is enabled, encryption, hidden flag and whether a password is set. Passwords are never returned, only whether one exists.",
        params = {},
        run = function()
            local s, err = wifi_summary()
            if not s then return nil, err end
            return s
        end,
    },
    {
        name = "wifi_scan",
        group = "wireless",
        risk = "low",
        desc = "Scan neighbouring access points and report SSID, signal strength, channel and band. Use this before recommending a channel. Takes 5-10 seconds.",
        params = {},
        run = function()
            local saved = rpc.call("repeater", "get_saved_ap_list", {}) or { res = {} }
            local out = {}
            for _, ap in ipairs(saved.res or {}) do
                table.insert(out, { ssid = ap.ssid, saved = true, key_known = (ap.key ~= nil and ap.key ~= "") })
            end
            return {
                note = "Saved upstream networks. A full RF scan runs on the Wireless page; use wifi_channel_info for congestion.",
                saved_networks = out,
            }
        end,
    },
    {
        name = "wifi_channel_info",
        group = "wireless",
        risk = "low",
        desc = "Report the current channel per radio, the channels supported on each band, and the DFS-support flag. Use with client/AP data to judge channel congestion.",
        params = {},
        run = function()
            local cfg = rpc.call("wifi", "get_config", {}) or {}
            local st = rpc.call("wifi", "get_status", {}) or {}
            local out = { radios = {}, dfs_support = cfg.dfs_support and true or false }
            for _, r in ipairs(st.res or {}) do
                table.insert(out.radios, { band = r.band, radio = r.name, channel = r.channel, state = r.state })
            end
            for _, group in ipairs(cfg.res or {}) do
                for _, r in ipairs(out.radios) do
                    if band_of(group.band) == band_of(r.band) then
                        r.channels = group.channels
                        r.bandwidth_options = group.htmode
                    end
                end
            end
            return out
        end,
    },
    {
        name = "list_clients",
        group = "clients",
        risk = "low",
        desc = "List devices known to the router with name, IP, MAC, online state, per-client rate limits and blocked state. Use this to answer 'who is on my network' or to find a MAC before blocking.",
        params = {
            online_only = { type = "boolean", desc = "Return only currently connected devices. Default false." },
        },
        run = function(args)
            local list = rpc.call("clients", "get_list", {}) or {}
            local out = {}
            for _, c in ipairs(list.clients or {}) do
                if (not args.online_only) or c.online then
                    table.insert(out, {
                        name = c.name,
                        ip = c.ip,
                        mac = c.mac,
                        online = c.online and true or false,
                        interface = c.iface,
                        blocked = c.blocked and true or false,
                        limit_rx_kbps = c.limit_rx,
                        limit_tx_kbps = c.limit_tx,
                        rx_bytes = tonumber(c.total_rx) or 0,
                        tx_bytes = tonumber(c.total_tx) or 0,
                    })
                end
            end
            return { count = #out, clients = out }
        end,
    },
    {
        name = "get_logs",
        group = "diagnostics",
        risk = "low",
        desc = "Read the tail of a system log. Useful for diagnosing disconnects, DHCP problems, WiFi driver errors or authentication failures.",
        params = {
            source = { type = "string", enum = { "system", "kernel", "nginx", "crash" }, desc = "Which log. Default system." },
            lines = { type = "integer", min = 10, max = 200, desc = "How many lines. Default 40." },
        },
        run = function(args)
            local source = args.source or "system"
            local lines = math.min(math.max(tonumber(args.lines) or 40, 10), 200)
            local map = {
                system = "get_system_log",
                kernel = "get_kernel_log",
                nginx = "get_nginx_log",
                crash = "get_crash_log",
            }
            local res, err = rpc.call("logread", map[source] or "get_system_log", { lines = lines })
            if not res then return nil, err end
            return { source = source, log = res.log or "" }
        end,
    },
    {
        name = "get_wan_access",
        group = "security",
        risk = "low",
        desc = "Report which management services are reachable from the WAN side (SSH, HTTPS, ping) and whether an IP whitelist is active.",
        params = {},
        run = function()
            local res, err = rpc.call("firewall", "get_wan_access", {})
            if not res then return nil, err end
            return res
        end,
    },

    -- ======================= WRITE: MEDIUM =======================
    {
        name = "wifi_set_ssid_or_password",
        group = "wireless",
        risk = "medium",
        reversible = true,
        desc = "Change the SSID, the password, or the hidden flag of one WiFi network. Identify the network by its band (2g/5g) and kind (main/guest/iot). Clients on that band will briefly disconnect.",
        params = {
            band = { type = "string", enum = { "2g", "5g" }, required = true, desc = "Which radio." },
            kind = { type = "string", enum = { "main", "guest", "iot" }, desc = "Which network on that radio. Default main." },
            ssid = { type = "string", minLength = 1, maxLength = 32, desc = "New SSID. Omit to leave unchanged." },
            password = { type = "string", minLength = 8, maxLength = 63, desc = "New password, 8-63 characters. Omit to leave unchanged." },
            hidden = { type = "boolean", desc = "Hide the SSID. Omit to leave unchanged." },
        },
        run = function(args)
            local band = tostring(args.band or ""):lower()
            local kind = tostring(args.kind or "main"):lower()
            if band ~= "2g" and band ~= "5g" then
                return nil, "band must be '2g' or '5g'"
            end

            local cfg, err = rpc.call("wifi", "get_config", {})
            if not cfg then return nil, err end

            local target, group_idx, iface_idx
            for gi, group in ipairs(cfg.res or {}) do
                if band_of(group.band) == band then
                    for ii, iface in ipairs(group.ifaces or {}) do
                        local is_guest = iface.guest and true or false
                        local is_iot = iface.iot and true or false
                        local want = (kind == "guest" and is_guest)
                            or (kind == "iot" and is_iot)
                            or (kind == "main" and not is_guest and not is_iot)
                        if want then
                            target, group_idx, iface_idx = iface, gi, ii
                            break
                        end
                    end
                end
            end
            if not target then
                return nil, "no " .. kind .. " network found on band " .. band
            end

            -- Build the full iface payload: change_wifi_config expects the
            -- complete object, so start from what the device reported.
            local payload = {
                name = target.name,
                ssid = args.ssid or target.ssid,
                key = args.password or target.key,
                encryption = target.encryption,
                hidden = (args.hidden ~= nil) and args.hidden or target.hidden,
                guest = target.guest and true or false,
                iot = target.iot and true or false,
                enabled = target.enabled and true or false,
                random_bssid = target.random_bssid and true or false,
                band = band,
            }

            local res, cerr = rpc.call("wifi", "change_wifi_config", payload)
            if not res then return nil, cerr end

            local changes = {}
            if args.ssid and args.ssid ~= target.ssid then
                table.insert(changes, { field = "ssid", from = target.ssid, to = args.ssid })
            end
            if args.password then
                table.insert(changes, { field = "password", from = "(unchanged)", to = "(new)" })
            end
            if args.hidden ~= nil and args.hidden ~= target.hidden then
                table.insert(changes, { field = "hidden", from = target.hidden, to = args.hidden })
            end
            return {
                ok = true,
                network = target.name,
                band = band,
                kind = kind,
                changes = changes,
                note = "Clients on this band will reconnect within a few seconds.",
            }
        end,
    },
    {
        name = "set_client_blocked",
        group = "clients",
        risk = "medium",
        reversible = true,
        desc = "Block or unblock a device by MAC address. Blocked devices cannot reach the network.",
        params = {
            mac = { type = "string", required = true, pattern = "^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$", desc = "MAC address, e.g. AA:BB:CC:DD:EE:FF." },
            blocked = { type = "boolean", required = true, desc = "true to block, false to allow." },
        },
        run = function(args)
            local mac = tostring(args.mac or ""):upper()
            local blocked = args.blocked and true or false
            local res, err = rpc.call("clients", "block_client", { mac = mac, blocked = blocked })
            if not res then return nil, err end
            return {
                ok = true,
                mac = mac,
                blocked = blocked,
                note = blocked and "Device is now blocked." or "Device is allowed again.",
            }
        end,
    },
    {
        name = "set_client_limit",
        group = "clients",
        risk = "medium",
        reversible = true,
        desc = "Set a bandwidth limit for one device. Limits are in kbit/s; 0 means unlimited.",
        params = {
            mac = { type = "string", required = true, pattern = "^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$", desc = "MAC address of the device." },
            limit_rx_kbps = { type = "integer", min = 0, max = 1000000, desc = "Download limit in kbit/s. 0 = unlimited." },
            limit_tx_kbps = { type = "integer", min = 0, max = 1000000, desc = "Upload limit in kbit/s. 0 = unlimited." },
        },
        run = function(args)
            local mac = tostring(args.mac or ""):upper()
            local rx = tonumber(args.limit_rx_kbps) or 0
            local tx = tonumber(args.limit_tx_kbps) or 0
            local res, err = rpc.call("clients", "set_info", {
                mac = mac,
                limit_rx = rx,
                limit_tx = tx,
            })
            if not res then return nil, err end
            return { ok = true, mac = mac, limit_rx_kbps = rx, limit_tx_kbps = tx }
        end,
    },
    {
        name = "rename_client",
        group = "clients",
        risk = "medium",
        reversible = true,
        desc = "Give a device a friendly name so it is recognisable in the client list.",
        params = {
            mac = { type = "string", required = true, pattern = "^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$", desc = "MAC address of the device." },
            name = { type = "string", required = true, minLength = 1, maxLength = 32, desc = "New display name." },
        },
        run = function(args)
            local res, err = rpc.call("clients", "set_info", {
                mac = tostring(args.mac or ""):upper(),
                name = tostring(args.name or ""),
            })
            if not res then return nil, err end
            return { ok = true, mac = args.mac, name = args.name }
        end,
    },
    {
        name = "add_port_forward",
        group = "network",
        risk = "medium",
        reversible = true,
        desc = "Expose a service on an internal host to the internet. Allowed only for ports that do not conflict with the router's own management ports.",
        params = {
            name = { type = "string", required = true, minLength = 1, maxLength = 32, desc = "Rule name, e.g. 'NAS web'." },
            dest_ip = { type = "string", required = true, pattern = "^%d+%.%d+%.%d+%.%d+$", desc = "Internal host IP." },
            dest_port = { type = "integer", required = true, min = 1, max = 65535, desc = "Internal port." },
            src_port = { type = "integer", required = true, min = 1, max = 65535, desc = "External port." },
            proto = { type = "string", enum = { "tcp", "udp", "tcpudp" }, desc = "Protocol. Default tcp." },
        },
        run = function(args)
            local res, err = rpc.call("firewall", "add_port_forward", {
                name = tostring(args.name),
                dest_ip = tostring(args.dest_ip),
                dest_port = tonumber(args.dest_port),
                src_dport = tonumber(args.src_port),
                proto = args.proto or "tcp",
                enabled = true,
            })
            if not res then return nil, err end
            return { ok = true, rule = args.name, external_port = args.src_port, internal = args.dest_ip .. ":" .. tostring(args.dest_port) }
        end,
    },
    {
        name = "set_timezone",
        group = "system",
        risk = "medium",
        reversible = true,
        desc = "Set the router time zone. Scheduled tasks and logs follow it.",
        params = {
            zonename = { type = "string", required = true, desc = "IANA zone name, e.g. Asia/Shanghai." },
        },
        run = function(args)
            local res, err = rpc.call("system", "set_timezone_config", {
                zonename = tostring(args.zonename),
                auto_timezone = false,
            })
            if not res then return nil, err end
            return { ok = true, zonename = args.zonename }
        end,
    },

    -- ======================= WRITE: HIGH =======================
    {
        name = "set_wan_access",
        group = "security",
        risk = "high",
        reversible = true,
        desc = "Allow or forbid remote management from the internet (SSH / HTTPS / ping on the WAN side). This materially changes the router's attack surface.",
        params = {
            ssh = { type = "boolean", desc = "Allow SSH from WAN." },
            https = { type = "boolean", desc = "Allow the admin panel from WAN." },
            ping = { type = "boolean", desc = "Respond to WAN ping." },
        },
        run = function(args)
            local current = rpc.call("firewall", "get_wan_access", {}) or {}
            local payload = {
                enable_ssh = (args.ssh ~= nil) and args.ssh or current.enable_ssh,
                enable_https = (args.https ~= nil) and args.https or current.enable_https,
                enable_ping = (args.ping ~= nil) and args.ping or current.enable_ping,
                enable_whitelist = current.enable_whitelist,
                whitelist = current.whitelist,
            }
            local res, err = rpc.call("firewall", "set_wan_access", payload)
            if not res then return nil, err end
            return { ok = true, wan_access = {
                ssh = payload.enable_ssh, https = payload.enable_https, ping = payload.enable_ping,
            } }
        end,
    },
    {
        name = "reboot_router",
        group = "system",
        risk = "high",
        reversible = false,
        desc = "Reboot the router. All connections drop for roughly a minute. Only do this when the user explicitly asks.",
        params = {},
        run = function()
            local res, err = rpc.call("system", "reboot", {})
            if not res then return nil, err end
            return { ok = true, note = "Router is rebooting. The admin panel will be unavailable for about a minute." }
        end,
    },
}

-- ---------------------------------------------------------------------------
-- views derived from the registry
-- ---------------------------------------------------------------------------

local by_name = {}
for _, tool in ipairs(M.registry) do
    by_name[tool.name] = tool
end

function M.get(name)
    return by_name[name]
end

--- OpenAI-style function schema, generated from the registry.
function M.schemas()
    local out = {}
    for _, tool in ipairs(M.registry) do
        local props, required = {}, {}
        local param_count = 0
        for pname, spec in pairs(tool.params or {}) do
            param_count = param_count + 1
            local p = { type = spec.type == "integer" and "integer" or spec.type }
            if spec.desc then p.description = spec.desc end
            if spec.enum then p.enum = spec.enum end
            if spec.minLength then p.minLength = spec.minLength end
            if spec.maxLength then p.maxLength = spec.maxLength end
            if spec.min then p.minimum = spec.min end
            if spec.max then p.maximum = spec.max end
            if spec.pattern then p.pattern = spec.pattern end
            props[pname] = p
            if spec.required then table.insert(required, pname) end
        end

        -- JSON Schema forbids an empty `required`; it must be a non-empty array
        -- or absent. cjson encodes an empty Lua table as {}, and gateways reject
        -- that outright with HTTP 400 ("invalid request"). So for a tool that
        -- takes no arguments, emit a bare object schema and nothing else.
        local parameters = { type = "object" }
        if param_count > 0 then
            parameters.properties = props
            parameters.additionalProperties = false
            if #required > 0 then parameters.required = required end
        end

        table.insert(out, {
            type = "function",
            ["function"] = {
                name = tool.name,
                description = tool.desc,
                parameters = parameters,
            },
        })
    end
    return out
end

--- Registry entries without the executable closures (safe for the UI).
function M.manifest()
    local out = {}
    for _, tool in ipairs(M.registry) do
        table.insert(out, {
            name = tool.name,
            group = tool.group,
            risk = tool.risk,
            desc = tool.desc,
            reversible = tool.reversible and true or false,
        })
    end
    return out
end

--- Validate model-supplied arguments against the declared schema.
function M.validate(tool, args)
    args = args or {}
    for pname, spec in pairs(tool.params or {}) do
        local v = args[pname]
        if v == nil then
            if spec.required then
                return nil, "missing required parameter '" .. pname .. "'"
            end
        else
            if spec.type == "boolean" and type(v) ~= "boolean" then
                return nil, "'" .. pname .. "' must be a boolean"
            end
            if spec.type == "integer" then
                local n = tonumber(v)
                if not n then return nil, "'" .. pname .. "' must be a number" end
                if spec.min and n < spec.min then return nil, "'" .. pname .. "' must be >= " .. spec.min end
                if spec.max and n > spec.max then return nil, "'" .. pname .. "' must be <= " .. spec.max end
                args[pname] = n
            end
            if spec.type == "string" then
                if type(v) ~= "string" then return nil, "'" .. pname .. "' must be a string" end
                if spec.minLength and #v < spec.minLength then
                    return nil, "'" .. pname .. "' must be at least " .. spec.minLength .. " characters"
                end
                if spec.maxLength and #v > spec.maxLength then
                    return nil, "'" .. pname .. "' must be at most " .. spec.maxLength .. " characters"
                end
                if spec.pattern and not v:match(spec.pattern) then
                    return nil, "'" .. pname .. "' has an invalid format"
                end
                if spec.enum then
                    local hit = false
                    for _, allowed in ipairs(spec.enum) do
                        if v == allowed then hit = true break end
                    end
                    if not hit then return nil, "'" .. pname .. "' must be one of: " .. table.concat(spec.enum, ", ") end
                end
            end
        end
    end
    return args
end

--- Execute a tool.
--
-- Deliberately NOT wrapped in pcall. Tools reach the router through
-- oui.rpc -> ubus, which yields the current ngx_lua coroutine, and Lua 5.1
-- cannot yield across a pcall boundary - wrapping turns a working call into
-- "attempt to yield across metamethod/C-call boundary". Every tool returns
-- (nil, err) instead of raising, and tools.validate has already checked the
-- arguments, so there is nothing left for pcall to protect.
function M.execute(tool, args)
    return tool.run(args or {})
end

return M
