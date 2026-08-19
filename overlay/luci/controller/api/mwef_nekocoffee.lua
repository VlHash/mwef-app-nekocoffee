module("luci.controller.api.mwef_nekocoffee", package.seeall)

local fs = require "nixio.fs"
local http = require "luci.http"
local json = require "luci.json"

local PLUGIN_ID = "mwef-app-nekocoffee"
local VERSION = "1.0.0"
local MWEF_BASE = "/data/other_vol/xqext"
local DEFAULT_PLUGIN_DIR = MWEF_BASE .. "/plugins"
local LOCK_DIR = "/tmp/mwef-nekocoffee.lock"

local installation_roots = {
    "/data/other_vol/ShellCrash",
    "/data/ShellCrash",
    "/etc/ShellCrash",
    "/data/other_vol/ShellClash",
    "/data/ShellClash"
}

local traffic_modes = {
    Redir = true,
    Mix = true,
    Tproxy = true,
    Tun = true
}

local dns_modes = {
    redir_host = "redir-host",
    ["fake-ip"] = "fake-ip"
}

local legacy_dns_modes = {
    mix = true,
    route = true
}

local proxy_modes = {
    rule = "Rule",
    global = "Global",
    direct = "Direct"
}

local function trim(value)
    return value and value:match("^%s*(.-)%s*$") or nil
end

local function read_file(path, limit)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local value = handle:read(limit or "*a")
    handle:close()
    return value
end

local function file_exists(path)
    local stat = fs.stat(path)
    return stat and stat.type == "reg" or false
end

local function directory_exists(path)
    local stat = fs.stat(path)
    return stat and stat.type == "dir" or false
end

local function shell_unquote(value)
    value = trim(value or "") or ""
    if #value >= 2 then
        local first = value:sub(1, 1)
        local last = value:sub(-1)
        if (first == "'" and last == "'") or (first == '"' and last == '"') then
            return value:sub(2, -2)
        end
    end
    return value
end

local function parse_shell_config(path)
    local values = {}
    local content = read_file(path) or ""
    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.-)%s*$")
        if key then values[key] = shell_unquote(value) end
    end
    return values
end

local function yaml_scalar(path, wanted)
    local content = read_file(path) or ""
    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([A-Za-z0-9_-]+)%s*:%s*(.-)%s*$")
        if key == wanted then
            value = trim(value or "") or ""
            local quote = value:sub(1, 1)
            if quote == "'" or quote == '"' then
                local closing = value:find(quote, 2, true)
                if closing then return value:sub(2, closing - 1) end
            end
            return trim((value:gsub("%s+#.*$", ""))) or ""
        end
    end
    return nil
end

local function first_file(paths)
    for _, path in ipairs(paths) do
        if file_exists(path) then return path end
    end
    return nil
end

local function detect_process()
    local iterator = fs.dir("/proc")
    if not iterator then return nil, nil, nil end
    for entry in iterator do
        if entry:match("^%d+$") then
            local command = read_file("/proc/" .. entry .. "/cmdline", 4096)
            if command then
                command = command:gsub("%z", " ")
                local lowered = command:lower()
                if lowered:find("crashcore", 1, true)
                    or lowered:find("/mihomo", 1, true)
                    or lowered:find("/clash", 1, true) then
                    for _, root in ipairs(installation_roots) do
                        if command:find(root, 1, true) then
                            return tonumber(entry), trim(command), root
                        end
                    end
                end
            end
        end
    end
    return nil, nil, nil
end

local function detect_installation()
    local pid, command, root = detect_process()
    if not root then
        for _, candidate in ipairs(installation_roots) do
            if directory_exists(candidate) then
                root = candidate
                break
            end
        end
    end

    if not root then
        return {
            detected = false,
            running = pid ~= nil,
            pid = pid
        }
    end

    local shell_name = root:find("ShellClash", 1, true) and "ShellClash" or "ShellCrash"
    local config_path = first_file({
        root .. "/configs/ShellCrash.cfg",
        root .. "/configs/ShellClash.cfg"
    })
    local runtime_yaml = first_file({
        "/tmp/ShellCrash/config.yaml",
        "/tmp/ShellClash/config.yaml",
        root .. "/config.yaml"
    })
    local user_yaml = first_file({
        root .. "/yamls/user.yaml",
        root .. "/yamls/user.yml"
    })
    local manager = first_file({ root .. "/start.sh" })
    local service = first_file({
        "/etc/init.d/shellcrash",
        "/etc/init.d/shellclash"
    })
    local version_path = first_file({
        root .. "/version",
        root .. "/configs/version",
        root .. "/configs/ShellCrash.version",
        root .. "/configs/ShellClash.version"
    })
    local config = config_path and parse_shell_config(config_path) or {}
    local version = version_path and trim((read_file(version_path, 128) or ""):match("[^\r\n]+")) or nil

    return {
        detected = true,
        name = shell_name,
        root = root,
        configPath = config_path,
        runtimeYaml = runtime_yaml,
        userYaml = user_yaml,
        manager = manager,
        service = service,
        version = version or config.version or config.crash_v,
        config = config,
        running = pid ~= nil,
        pid = pid,
        command = command
    }
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_succeeded(result)
    return result == true or result == 0
end

local function find_executable(names)
    for _, name in ipairs(names) do
        if file_exists(name) then return name end
    end
    return nil
end

local function capture(command, limit)
    local handle = io.popen(command .. " 2>/dev/null", "r")
    if not handle then return nil, false end
    local output = handle:read(limit or 16384) or ""
    local result = handle:close()
    return output, command_succeeded(result)
end

local function controller_details(installation)
    local yaml = installation.runtimeYaml
    local endpoint = yaml and yaml_scalar(yaml, "external-controller") or nil
    local port = endpoint and tonumber(endpoint:match(":(%d+)$")) or nil
    if not port then
        local hostdir = installation.config.hostdir or ""
        port = tonumber(hostdir:match("(%d+)%s*/"))
    end
    port = port or tonumber(installation.config.db_port) or 9999
    if port < 1 or port > 65535 then port = 9999 end
    local secret = yaml and yaml_scalar(yaml, "secret") or ""
    return port, secret or ""
end

local function controller_request(installation, path, method, body)
    local curl = find_executable({ "/usr/bin/curl", "/bin/curl", "/usr/sbin/curl" })
    if not curl or not installation.running then return nil, "controller unavailable" end
    local port, secret = controller_details(installation)
    local command = shell_quote(curl)
        .. " -fsS --connect-timeout 1 --max-time 3"
        .. " -H " .. shell_quote("Accept: application/json")
    if secret ~= "" then
        command = command .. " -H " .. shell_quote("Authorization: Bearer " .. secret)
    end
    if method and method ~= "GET" then
        command = command
            .. " -X " .. shell_quote(method)
            .. " -H " .. shell_quote("Content-Type: application/json")
            .. " --data-binary " .. shell_quote(body or "{}")
    end
    command = command .. " " .. shell_quote("http://127.0.0.1:" .. tostring(port) .. path)
    local output, ok = capture(command, 32768)
    if not ok then return nil, "controller request failed" end
    if not output or output == "" then return {}, nil end
    local decoded_ok, data = pcall(json.decode, output)
    if not decoded_ok or type(data) ~= "table" then return nil, "invalid controller response" end
    return data, nil
end

local function read_grants()
    local plugin_dir = trim(read_file(MWEF_BASE .. "/config/plugin-directory", 256))
    if not plugin_dir or not plugin_dir:match("^/data/[A-Za-z0-9%._/%-]+$")
        or plugin_dir:find("..", 1, true) then
        plugin_dir = DEFAULT_PLUGIN_DIR
    end
    local values = {}
    local content = read_file(plugin_dir .. "/" .. PLUGIN_ID .. "/.grants") or ""
    for line in content:gmatch("[^\r\n]+") do
        line = trim(line)
        if line and line ~= "" then values[line] = true end
    end
    return values
end

local function grants_array(grants)
    local result = {}
    for key in pairs(grants) do result[#result + 1] = key end
    table.sort(result)
    return result
end

local function require_grants(required)
    local grants = read_grants()
    local missing = {}
    for _, permission in ipairs(required) do
        if not grants[permission] then missing[#missing + 1] = permission end
    end
    if #missing > 0 then
        return false, "Missing permission grant: " .. table.concat(missing, ", ")
    end
    return true
end

local function dashboard_details(installation)
    if not installation.detected then return { available = false } end
    local port, secret = controller_details(installation)
    local path = "/ui/"
    local hostdir = installation.config.hostdir or ""
    local configured_path = hostdir:match("%d+%s*(/[%w%-%._/]+)")
    if configured_path then path = configured_path end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    if path:sub(-1) ~= "/" then path = path .. "/" end
    return {
        available = installation.running,
        port = port,
        path = path,
        secretSet = secret ~= ""
    }
end

local function normalize_proxy_mode(value)
    value = tostring(value or ""):lower()
    if value == "rule" or value == "global" or value == "direct" then return value end
    return nil
end

local function collect_status()
    local grants = read_grants()
    if not grants["system.read"] or not grants["filesystem.read"] then
        local missing = {}
        if not grants["system.read"] then missing[#missing + 1] = "system.read" end
        if not grants["filesystem.read"] then missing[#missing + 1] = "filesystem.read" end
        return {
            code = 0,
            plugin = { id = PLUGIN_ID, version = VERSION },
            timestamp = os.time(),
            grants = grants_array(grants),
            permissionMissing = missing,
            installation = { detected = false, running = false },
            runtime = { controllerReady = false },
            settings = {
                trafficOptions = { "Mix", "Redir", "Tproxy", "Tun" },
                dnsOptions = { "redir_host", "fake-ip" },
                mixedPort = 7890
            },
            dashboard = { available = false }
        }
    end

    local installation = detect_installation()
    local runtime = {}
    local config = installation.config or {}

    if installation.detected and installation.runtimeYaml then
        runtime.proxyMode = normalize_proxy_mode(yaml_scalar(installation.runtimeYaml, "mode"))
        runtime.dnsEnhancedMode = yaml_scalar(installation.runtimeYaml, "enhanced-mode")
    end

    if installation.detected and installation.running
        and grants["network.client"] and grants["shell.execute"] then
        local controller_config = controller_request(installation, "/configs", "GET")
        if controller_config then
            runtime.proxyMode = normalize_proxy_mode(controller_config.mode) or runtime.proxyMode
            runtime.controllerReady = true
        else
            runtime.controllerReady = false
        end
        if not config.core_v or config.core_v == "" then
            local version_data = controller_request(installation, "/version", "GET")
            if version_data then runtime.coreVersion = version_data.version end
        end
    end

    runtime.coreVersion = runtime.coreVersion or config.core_v

    return {
        code = 0,
        plugin = { id = PLUGIN_ID, version = VERSION },
        timestamp = os.time(),
        grants = grants_array(grants),
        installation = {
            detected = installation.detected,
            name = installation.name,
            root = installation.root,
            version = installation.version,
            core = config.crashcore,
            coreVersion = runtime.coreVersion,
            running = installation.running,
            pid = installation.pid
        },
        runtime = {
            proxyMode = runtime.proxyMode,
            controllerReady = runtime.controllerReady == true,
            dnsEnhancedMode = runtime.dnsEnhancedMode
        },
        settings = {
            trafficMode = config.redir_mod,
            dnsMode = config.dns_mod,
            trafficOptions = { "Mix", "Redir", "Tproxy", "Tun" },
            dnsOptions = { "redir_host", "fake-ip" },
            mixedPort = tonumber(config.mix_port) or 7890
        },
        dashboard = dashboard_details(installation)
    }
end

local function write_atomic(path, value)
    local random_handle = io.open("/dev/urandom", "rb")
    local random = random_handle and random_handle:read(6) or nil
    if random_handle then random_handle:close() end
    local suffix = tostring(os.time()) .. "."
    if random then
        for index = 1, #random do suffix = suffix .. string.format("%02x", random:byte(index)) end
    else
        suffix = suffix .. tostring(math.random(100000, 999999))
    end
    local temporary = path .. ".nekocoffee.tmp." .. suffix
    local handle = io.open(temporary, "wb")
    if not handle then return false end
    local write_called, write_result = pcall(handle.write, handle, value)
    local flush_called, flush_result = pcall(handle.flush, handle)
    local close_called, close_result = pcall(handle.close, handle)
    if not write_called or not write_result
        or not flush_called or not flush_result
        or not close_called or not close_result then
        if not close_called or not close_result then pcall(handle.close, handle) end
        os.remove(temporary)
        return false
    end
    local stat = fs.stat(path)
    if stat and stat.mode then
        local chmod_called, chmod_result = pcall(fs.chmod, temporary, stat.mode)
        if not chmod_called or not chmod_result then
            os.remove(temporary)
            return false
        end
    end
    if read_file(temporary) ~= value then
        os.remove(temporary)
        return false
    end
    if os.rename(temporary, path) then return true end
    os.remove(temporary)
    return false
end

local function write_with_backup(path, original, updated)
    if original == updated then return true, false end
    if not write_atomic(path .. ".nekocoffee.bak", original) then
        return false, false
    end
    if not write_atomic(path, updated) then return false, false end
    return true, true
end

local function replace_shell_values(content, replacements)
    local normalized = content:gsub("\r\n", "\n")
    local ended = normalized:sub(-1) == "\n"
    if not ended then normalized = normalized .. "\n" end
    local lines = {}
    local found = {}
    for line in normalized:gmatch("([^\n]*)\n") do
        local key = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=")
        if key and replacements[key] ~= nil then
            lines[#lines + 1] = key .. "=" .. replacements[key]
            found[key] = true
        else
            lines[#lines + 1] = line
        end
    end
    for key, value in pairs(replacements) do
        if not found[key] then lines[#lines + 1] = key .. "=" .. value end
    end
    local result = table.concat(lines, "\n")
    if ended then result = result .. "\n" end
    return result
end

local function replace_dns_enhanced_mode(content, value)
    local normalized = content:gsub("\r\n", "\n")
    local ended = normalized:sub(-1) == "\n"
    if not ended then normalized = normalized .. "\n" end
    local lines = {}
    local in_dns = false
    local found = false
    local dns_found = false
    local child_indent

    for line in normalized:gmatch("([^\n]*)\n") do
        local indent, key, tail = line:match("^([ \t]*)([A-Za-z0-9_-]+)%s*:%s*(.*)$")
        if key and #indent == 0 then
            if in_dns and not found then
                lines[#lines + 1] = (child_indent or "  ") .. "enhanced-mode: " .. value
                found = true
            end
            in_dns = key == "dns"
            if in_dns then
                dns_found = true
                local inline = trim((tail or ""):gsub("#.*$", "")) or ""
                if inline ~= "" then return nil, "inline dns mappings are not supported" end
            end
        elseif in_dns and key then
            if not child_indent then child_indent = indent end
            if indent == child_indent and key == "enhanced-mode" then
                line = indent .. "enhanced-mode: " .. value
                found = true
            end
        end
        lines[#lines + 1] = line
    end

    if in_dns and not found then
        lines[#lines + 1] = (child_indent or "  ") .. "enhanced-mode: " .. value
        found = true
    end
    if not dns_found then return nil, "user.yaml has no top-level dns section" end

    local result = table.concat(lines, "\n")
    if ended then result = result .. "\n" end
    return result
end

local function run_service(installation, operation)
    if not installation.detected then return false, "ShellClash installation not found" end
    local command
    if installation.manager then
        command = "ash " .. shell_quote(installation.manager) .. " " .. operation
    elseif installation.service then
        command = shell_quote(installation.service) .. " " .. operation
    else
        return false, "ShellClash service entry not found"
    end
    local result = os.execute(command .. " >/dev/null 2>&1")
    if command_succeeded(result) then return true end
    return false, "ShellClash service operation failed"
end

local function acquire_lock()
    local existing = fs.stat(LOCK_DIR)
    if existing and existing.type == "dir" and existing.mtime
        and os.time() - existing.mtime > 60 then
        pcall(fs.rmdir, LOCK_DIR)
    end
    return fs.mkdir(LOCK_DIR) == true
end

local function release_lock()
    pcall(fs.rmdir, LOCK_DIR)
end

local function with_lock(callback)
    if not acquire_lock() then return nil, "Another NekoCoffee operation is in progress" end
    local ok, result, message = pcall(callback)
    release_lock()
    if not ok then return nil, tostring(result) end
    return result, message
end

local function change_settings(installation, traffic_mode, dns_mode)
    if not installation.configPath then return nil, "ShellClash configuration not found" end
    if not traffic_modes[traffic_mode] then return nil, "Unsupported traffic mode" end

    local original_config = read_file(installation.configPath)
    if not original_config then return nil, "Unable to read ShellClash configuration" end
    local current_config = parse_shell_config(installation.configPath)
    local preserved_legacy_dns = legacy_dns_modes[dns_mode] and current_config.dns_mod == dns_mode
    if not dns_modes[dns_mode] and not preserved_legacy_dns then
        return nil, "Unsupported DNS mode"
    end
    local updated_config = replace_shell_values(original_config, {
        redir_mod = traffic_mode,
        dns_mod = dns_mode
    })

    local original_yaml
    local updated_yaml
    if installation.userYaml and dns_modes[dns_mode] then
        original_yaml = read_file(installation.userYaml)
        if not original_yaml then return nil, "Unable to read user.yaml" end
        local yaml_error
        updated_yaml, yaml_error = replace_dns_enhanced_mode(original_yaml, dns_modes[dns_mode])
        if not updated_yaml then return nil, yaml_error end
    end

    local config_ok, config_changed = write_with_backup(
        installation.configPath,
        original_config,
        updated_config
    )
    if not config_ok then return nil, "Unable to save ShellClash configuration" end

    local yaml_changed = false
    if installation.userYaml and dns_modes[dns_mode] then
        local yaml_ok
        yaml_ok, yaml_changed = write_with_backup(installation.userYaml, original_yaml, updated_yaml)
        if not yaml_ok then
            if config_changed then write_atomic(installation.configPath, original_config) end
            return nil, "Unable to save user.yaml"
        end
    end

    if installation.running and (config_changed or yaml_changed) then
        local restarted, restart_error = run_service(installation, "restart")
        if not restarted then return nil, "Settings saved, but restart failed: " .. restart_error end
    end
    return true
end

local function valid_ipv4(value)
    value = trim(value or "") or ""
    if #value < 7 or #value > 15 then return nil end
    local parts = {}
    for part in value:gmatch("[^.]+") do parts[#parts + 1] = part end
    if #parts ~= 4 then return nil end
    for _, part in ipairs(parts) do
        if not part:match("^%d+$") or tonumber(part) > 255 then return nil end
    end
    return value
end

local function check_ip(proxy_port)
    local curl = find_executable({ "/usr/bin/curl", "/bin/curl", "/usr/sbin/curl" })
    if not curl then return nil, "curl is unavailable" end
    local base = shell_quote(curl)
        .. " -4 -fsS --connect-timeout 3 --max-time 7 --max-filesize 128"
    local url = shell_quote("https://api.ipify.org")
    local direct_output = capture(base .. " --noproxy '*' " .. url, 128)
    local direct_ip = valid_ipv4(direct_output)
    local proxy_ip
    if proxy_port and proxy_port >= 1 and proxy_port <= 65535 then
        local proxy_output = capture(
            base .. " --proxy " .. shell_quote("http://127.0.0.1:" .. tostring(proxy_port)) .. " " .. url,
            128
        )
        proxy_ip = valid_ipv4(proxy_output)
    end
    if not direct_ip and not proxy_ip then return nil, "Public IP check failed" end
    return {
        direct = direct_ip,
        proxy = proxy_ip,
        timestamp = os.time()
    }
end

local function valid_session()
    local request_uri = os.getenv("REQUEST_URI") or ""
    local token = request_uri:match(";stok=([a-fA-F0-9]+)")
    if not token or #token < 16 or #token > 64 then return false end
    local session = fs.stat("/tmp/luci-sessions/" .. token)
    return session and session.type == "reg" or false
end

local function respond(data, status)
    http.header("Cache-Control", "no-store")
    http.header("X-Content-Type-Options", "nosniff")
    if status then
        local label = status == 400 and "Bad Request"
            or status == 401 and "Unauthorized"
            or status == 403 and "Forbidden"
            or status == 409 and "Conflict"
            or "Internal Server Error"
        http.status(status, label)
    end
    http.prepare_content("application/json")
    http.write(json.encode(data))
end

local function require_post()
    if (os.getenv("REQUEST_METHOD") or "GET") ~= "POST" then
        respond({ code = 405, message = "POST required" }, 400)
        return false
    end
    return true
end

local function handle_control()
    if not require_post() then return end
    local allowed, grant_error = require_grants({
        "system.read", "filesystem.read", "service.control", "shell.execute"
    })
    if not allowed then return respond({ code = 403, message = grant_error }, 403) end
    local operation = http.formvalue("operation") or ""
    if operation ~= "start" and operation ~= "stop" and operation ~= "restart" then
        return respond({ code = 400, message = "Unsupported service operation" }, 400)
    end
    local result, message = with_lock(function()
        local installation = detect_installation()
        if operation == "start" and installation.running then
            return nil, "ShellClash is already running"
        end
        if operation ~= "start" and not installation.running then
            return nil, "ShellClash is not running"
        end
        return run_service(installation, operation)
    end)
    if not result then return respond({ code = 500, message = message }, 500) end
    respond(collect_status())
end

local function handle_proxy_mode()
    if not require_post() then return end
    local allowed, grant_error = require_grants({
        "system.read", "filesystem.read", "network.client", "shell.execute"
    })
    if not allowed then return respond({ code = 403, message = grant_error }, 403) end
    local requested = http.formvalue("mode") or ""
    local runtime_value = proxy_modes[requested]
    if not runtime_value then return respond({ code = 400, message = "Unsupported proxy mode" }, 400) end
    local installation = detect_installation()
    if not installation.running then return respond({ code = 409, message = "ShellClash is not running" }, 409) end
    local _, error_message = controller_request(
        installation,
        "/configs",
        "PATCH",
        json.encode({ mode = runtime_value })
    )
    if error_message then return respond({ code = 500, message = error_message }, 500) end
    respond(collect_status())
end

local function handle_settings()
    if not require_post() then return end
    local allowed, grant_error = require_grants({
        "system.read", "filesystem.read", "filesystem.write", "service.control", "shell.execute"
    })
    if not allowed then return respond({ code = 403, message = grant_error }, 403) end
    local traffic_mode = http.formvalue("trafficMode") or ""
    local dns_mode = http.formvalue("dnsMode") or ""
    local result, message = with_lock(function()
        return change_settings(detect_installation(), traffic_mode, dns_mode)
    end)
    if not result then return respond({ code = 500, message = message }, 500) end
    respond(collect_status())
end

local function handle_ip_check()
    if not require_post() then return end
    local allowed, grant_error = require_grants({
        "system.read", "filesystem.read", "network.client", "shell.execute"
    })
    if not allowed then return respond({ code = 403, message = grant_error }, 403) end
    local installation = detect_installation()
    local config = installation.config or {}
    local result, message = check_ip(tonumber(config.mix_port) or 7890)
    if not result then return respond({ code = 502, message = message }, 500) end
    respond({ code = 0, ip = result })
end

function index()
    -- The authenticated route is registered by luci.controller.web.mwef_nekocoffee.
end

function dispatch()
    if not valid_session() then return respond({ code = 401, message = "Invalid token" }, 401) end
    local query = os.getenv("QUERY_STRING") or ""
    local action = query:match("^action=([a-z%-]+)")
        or query:match("&action=([a-z%-]+)")
        or "status"

    if action == "status" then
        local ok, data = pcall(collect_status)
        if ok then return respond(data) end
        return respond({ code = 500, message = tostring(data) }, 500)
    end
    if action == "control" then return handle_control() end
    if action == "proxy-mode" then return handle_proxy_mode() end
    if action == "settings" then return handle_settings() end
    if action == "ip-check" then return handle_ip_check() end
    respond({ code = 404, message = "Unknown action" }, 400)
end
