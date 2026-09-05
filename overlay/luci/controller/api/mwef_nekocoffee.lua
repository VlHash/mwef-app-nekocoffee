module("luci.controller.api.mwef_nekocoffee", package.seeall)

local fs = require "nixio.fs"
local http = require "luci.http"
local json = require "luci.json"

local PLUGIN_ID = "mwef-app-nekocoffee"
local VERSION = "1.2.0"
local MWEF_BASE = "/data/other_vol/xqext"
local DEFAULT_PLUGIN_DIR = MWEF_BASE .. "/plugins"
local LOCK_DIR = "/tmp/mwef-nekocoffee.lock"
local MAX_PROFILE_SIZE = 2 * 1024 * 1024

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

local function random_suffix()
    local handle = io.open("/dev/urandom", "rb")
    local random = handle and handle:read(8) or nil
    if handle then handle:close() end
    local suffix = tostring(os.time()) .. "."
    if random then
        for index = 1, #random do
            suffix = suffix .. string.format("%02x", random:byte(index))
        end
    else
        suffix = suffix .. tostring(math.random(100000, 999999))
    end
    return suffix
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

local write_atomic

local function valid_profile_name(value)
    value = trim(value or "") or ""
    value = value:match("([^/\\]+)$") or value
    if #value < 6 or #value > 80 or value:find("..", 1, true) then return nil end
    if not value:match("^[A-Za-z0-9][A-Za-z0-9._%-]*%.[Yy][Aa][Mm][Ll]$")
        and not value:match("^[A-Za-z0-9][A-Za-z0-9._%-]*%.[Yy][Mm][Ll]$") then
        return nil
    end
    return value
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

local function private_ipv4(value)
    local ip = valid_ipv4(value)
    if not ip then return nil end
    local first, second = ip:match("^(%d+)%.(%d+)")
    first, second = tonumber(first), tonumber(second)
    if first == 10 or (first == 172 and second >= 16 and second <= 31)
        or (first == 192 and second == 168) then
        return ip
    end
    return nil
end

local function valid_mac(value)
    value = trim(value or "") or ""
    if not value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return nil end
    value = value:upper()
    local first = tonumber(value:sub(1, 2), 16)
    if not first or first % 2 == 1 or value == "00:00:00:00:00:00" then return nil end
    return value
end

local function read_nonempty_lines(path)
    local values = {}
    local content = read_file(path) or ""
    for line in content:gmatch("[^\r\n]+") do
        line = trim(line)
        if line and line ~= "" then values[#values + 1] = line end
    end
    return values
end

local function collect_device_policy(installation)
    local config = installation.config or {}
    local mode = config.macfilter_type == "白名单" and "whitelist" or "blacklist"
    local devices = {}
    local by_mac = {}
    local filter_path = installation.detected and (installation.root .. "/configs/mac") or nil
    local ip_filter_path = installation.detected and (installation.root .. "/configs/ip_filter") or nil
    local configured_macs = {}

    local function add_device(ip, mac, name, online, source)
        mac = valid_mac(mac)
        if not mac then return end
        ip = private_ipv4(ip)
        name = trim(name or "") or ""
        if name == "*" then name = "" end
        name = name:gsub("[%c]", "")
        local device = by_mac[mac]
        if not device then
            device = { mac = mac, online = false }
            by_mac[mac] = device
            devices[#devices + 1] = device
        end
        if ip then device.ip = ip end
        if name ~= "" then device.name = name end
        if online then device.online = true end
        if source then device.source = source end
    end

    if filter_path then
        for _, value in ipairs(read_nonempty_lines(filter_path)) do
            local mac = valid_mac(value)
            if mac and not configured_macs[mac] then
                configured_macs[mac] = true
                add_device(nil, mac, nil, false, "configured")
            end
        end
    end

    local lease_paths = {
        "/var/lib/dhcp/dhcpd.leases",
        "/var/lib/dhcpd/dhcpd.leases",
        "/tmp/dhcp.leases",
        "/tmp/dnsmasq.leases"
    }
    for _, path in ipairs(lease_paths) do
        if file_exists(path) then
            local content = read_file(path, 512 * 1024) or ""
            for line in content:gmatch("[^\r\n]+") do
                local _, mac, ip, name = line:match("^%s*(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
                if mac and ip then add_device(ip, mac, name, true, "dhcp") end
            end
        end
    end

    local arp = read_file("/proc/net/arp", 256 * 1024) or ""
    for line in arp:gmatch("[^\r\n]+") do
        local ip, _, flags, mac, _, interface = line:match(
            "^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)"
        )
        local lan_interface = interface and (
            interface == "br0" or interface == "br-lan"
                or interface:match("^br[%w%._%-]+$") or interface:match("^lan[%w%._%-]*$")
        )
        if flags and flags ~= "0x0" and lan_interface then
            add_device(ip, mac, nil, true, "arp")
        end
    end

    for _, device in ipairs(devices) do
        device.configured = configured_macs[device.mac] == true
        if mode == "whitelist" then
            device.proxy = device.configured
        else
            device.proxy = not device.configured
        end
        device.configuredOnly = device.configured and not device.online and not device.ip
    end
    table.sort(devices, function(left, right)
        if left.online ~= right.online then return left.online end
        local left_name = (left.name or ""):lower()
        local right_name = (right.name or ""):lower()
        if left_name ~= right_name then return left_name < right_name end
        if (left.ip or "") ~= (right.ip or "") then return (left.ip or "") < (right.ip or "") end
        return left.mac < right.mac
    end)

    return {
        mode = mode,
        devices = devices,
        configuredMacCount = filter_path and #read_nonempty_lines(filter_path) or 0,
        ipFilterCount = ip_filter_path and #read_nonempty_lines(ip_filter_path) or 0,
        firewallArea = config.firewall_area
    }
end

local function profile_content_valid(content)
    if not content or #content == 0 then return false, "Configuration file is empty" end
    if #content > MAX_PROFILE_SIZE then return false, "Configuration file exceeds 2 MiB" end
    if content:find("%z") then return false, "Configuration file contains binary data" end
    local normalized = "\n" .. content:gsub("\r\n", "\n")
    if not normalized:match("\nproxies:%s*")
        and not normalized:match("\nproxy%-providers:%s*")
        and not normalized:match("\nproxy%-groups:%s*")
        and not normalized:match("\nrules:%s*") then
        return false, "No supported top-level Clash configuration section was found"
    end
    return true
end

local function active_profile_name(installation)
    if not installation.detected then return nil end
    local link = installation.root .. "/yamls/config.yaml"
    local ok, target = pcall(fs.readlink, link)
    if not ok or not target then return nil end
    local name = target:match("([^/]+)$")
    return valid_profile_name(name)
end

local function list_profiles(installation)
    local profiles = {}
    if not installation.detected then return profiles end
    local directory = installation.root .. "/providers"
    local iterator = fs.dir(directory)
    if not iterator then return profiles end
    local active = active_profile_name(installation)
    for entry in iterator do
        local name = valid_profile_name(entry)
        if name then
            local stat = fs.stat(directory .. "/" .. name)
            if stat and stat.type == "reg" then
                profiles[#profiles + 1] = {
                    name = name,
                    size = tonumber(stat.size) or 0,
                    modified = tonumber(stat.mtime) or 0,
                    active = name == active
                }
            end
        end
    end
    table.sort(profiles, function(left, right)
        if left.active ~= right.active then return left.active end
        return left.name:lower() < right.name:lower()
    end)
    return profiles
end

local function save_profile(installation, name, content)
    name = valid_profile_name(name)
    if not name then return nil, "Use an ASCII .yaml or .yml file name (letters, numbers, dot, dash, underscore)" end
    local valid, validation_error = profile_content_valid(content)
    if not valid then return nil, validation_error end
    local directory = installation.root .. "/providers"
    if not directory_exists(directory) then return nil, "ShellClash providers directory not found" end
    local target = directory .. "/" .. name
    if fs.stat(target) then return nil, "A configuration with this name already exists" end
    if not write_atomic(target, content) then return nil, "Unable to save configuration file" end
    return true
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
                dnsOptions = { "redir_host", "fake-ip", "mix", "route" },
                mixedPort = 7890,
                ipv6Proxy = false,
                quicProxy = true
            },
            profiles = {},
            devicePolicy = { mode = "blacklist", devices = {}, ipFilterCount = 0 },
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
            dnsOptions = { "redir_host", "fake-ip", "mix", "route" },
            mixedPort = tonumber(config.mix_port) or 7890,
            ipv6Proxy = config.ipv6_redir == "ON",
            quicProxy = config.quic_rj ~= "ON"
        },
        profiles = list_profiles(installation),
        devicePolicy = collect_device_policy(installation),
        dashboard = dashboard_details(installation)
    }
end

write_atomic = function(path, value)
    local suffix = random_suffix()
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
        and os.time() - existing.mtime > 180 then
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

local function change_settings(installation, traffic_mode, dns_mode, ipv6_proxy, quic_proxy)
    if not installation.configPath then return nil, "ShellClash configuration not found" end
    if not traffic_modes[traffic_mode] then return nil, "Unsupported traffic mode" end
    local current_dns = (installation.config or {}).dns_mod
    local preserving_legacy_dns = legacy_dns_modes[dns_mode] and current_dns == dns_mode
    if not dns_modes[dns_mode] and not preserving_legacy_dns then
        return nil, "Unsupported DNS mode"
    end
    if ipv6_proxy ~= "1" and ipv6_proxy ~= "0" then return nil, "Invalid IPv6 setting" end
    if quic_proxy ~= "1" and quic_proxy ~= "0" then return nil, "Invalid QUIC setting" end

    local original_config = read_file(installation.configPath)
    if not original_config then return nil, "Unable to read ShellClash configuration" end
    local replacements = {
        redir_mod = traffic_mode,
        dns_mod = dns_mode,
        ipv6_redir = ipv6_proxy == "1" and "ON" or "OFF",
        quic_rj = quic_proxy == "1" and "OFF" or "ON"
    }
    if ipv6_proxy == "1" then replacements.ipv6_support = "ON" end
    if dns_mode == "fake-ip" then
        replacements.cn_ip_route = "OFF"
        replacements.cn_ipv6_route = "OFF"
    end
    local updated_config = replace_shell_values(original_config, replacements)

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

local function parse_mac_list(value)
    value = tostring(value or "")
    if #value > 4608 then return nil, "Device list is too large" end
    local values = {}
    local seen = {}
    for item in value:gmatch("[^,%s]+") do
        local mac = valid_mac(item)
        if not mac then return nil, "Invalid device MAC address" end
        if not seen[mac] then
            seen[mac] = true
            values[#values + 1] = mac
            if #values > 128 then return nil, "At most 128 devices can be configured" end
        end
    end
    table.sort(values)
    return values
end

local function change_device_policy(installation, mode, mac_list)
    if not installation.detected or not installation.root then
        return nil, "ShellClash installation not found"
    end
    if not installation.configPath then return nil, "ShellClash configuration not found" end
    if mode ~= "blacklist" and mode ~= "whitelist" then
        return nil, "Unsupported device policy"
    end
    local macs, parse_error = parse_mac_list(mac_list)
    if not macs then return nil, parse_error end
    if mode == "whitelist" and #macs == 0 then
        return nil, "Select at least one proxy device when new devices default to direct"
    end

    local configs_directory = installation.root .. "/configs"
    if not directory_exists(configs_directory) then return nil, "ShellClash configs directory not found" end
    local mac_path = configs_directory .. "/mac"
    local mac_stat = fs.stat(mac_path)
    local original_mac = read_file(mac_path)
    if mac_stat and not original_mac then return nil, "Unable to read device list" end
    original_mac = original_mac or ""
    local original_config = read_file(installation.configPath)
    if not original_config then return nil, "Unable to read ShellClash configuration" end

    local updated_mac = #macs > 0 and (table.concat(macs, "\n") .. "\n") or ""
    local filter_type = mode == "whitelist" and "白名单" or "黑名单"
    local updated_config = replace_shell_values(original_config, { macfilter_type = filter_type })
    local mac_changed = original_mac ~= updated_mac
    local config_changed = original_config ~= updated_config
    if not mac_changed and not config_changed then return true end

    local config_ok
    config_ok, config_changed = write_with_backup(
        installation.configPath,
        original_config,
        updated_config
    )
    if not config_ok then return nil, "Unable to save device policy" end

    local mac_ok
    mac_ok, mac_changed = write_with_backup(mac_path, original_mac, updated_mac)
    if not mac_ok then
        if config_changed and not write_atomic(installation.configPath, original_config) then
            return nil, "Unable to save device list or restore the previous configuration"
        end
        return nil, "Unable to save device list"
    end

    if installation.running then
        local restarted, restart_error = run_service(installation, "restart")
        if not restarted then
            local restored = true
            if mac_changed and not write_atomic(mac_path, original_mac) then restored = false end
            if config_changed and not write_atomic(installation.configPath, original_config) then
                restored = false
            end
            if not restored then
                return nil, "Restart failed and the previous device policy could not be restored: "
                    .. restart_error
            end
            local recovered = run_service(detect_installation(), "restart")
            if recovered then
                return nil, "Restart failed; the previous device policy was restored: " .. restart_error
            end
            return nil, "Restart failed and recovery could not be confirmed: " .. restart_error
        end
    end
    return true
end

local function check_ip(proxy_port)
    local curl = find_executable({ "/usr/bin/curl", "/bin/curl", "/usr/sbin/curl" })
    if not curl then return nil, "curl is unavailable" end
    local direct_endpoints = {
        { url = "https://api.ip.sb/ip", source = "api.ip.sb" },
        { url = "https://api.ipify.org", source = "api.ipify.org" },
        { url = "https://v4.ident.me", source = "v4.ident.me" }
    }
    local proxy_endpoints = {
        { url = "https://api.ipify.org", source = "api.ipify.org" },
        { url = "https://v4.ident.me", source = "v4.ident.me" },
        { url = "https://api.ip.sb/ip", source = "api.ip.sb" }
    }
    local function try_endpoints(endpoints, transport, max_time)
        local base = shell_quote(curl)
            .. " -4 -fsS --connect-timeout 3 --max-time " .. tostring(max_time)
            .. " --max-filesize 128 -A " .. shell_quote("NekoCoffee/" .. VERSION)
        for _, endpoint in ipairs(endpoints) do
            local output, ok = capture(base .. " " .. transport .. " " .. shell_quote(endpoint.url), 128)
            local ip = ok and valid_ipv4(output) or nil
            if ip then return { ip = ip, source = endpoint.source } end
        end
        return { error = "All public IP services failed" }
    end
    local direct = try_endpoints(direct_endpoints, "--noproxy '*'", 6)
    local proxy
    if proxy_port and proxy_port >= 1 and proxy_port <= 65535 then
        proxy = try_endpoints(
            proxy_endpoints,
            "--proxy " .. shell_quote("http://127.0.0.1:" .. tostring(proxy_port)),
            10
        )
    else
        proxy = { error = "Mixed proxy port is unavailable" }
    end
    return {
        direct = direct,
        proxy = proxy,
        timestamp = os.time()
    }
end

local function public_ipv4(value)
    local ip = valid_ipv4(value)
    if not ip then return nil end
    for part in ip:gmatch("[^.]+") do
        if #part > 1 and part:sub(1, 1) == "0" then return nil end
    end
    local first, second = ip:match("^(%d+)%.(%d+)")
    first, second = tonumber(first), tonumber(second)
    if first == 0 or first == 10 or first == 127 or first >= 224
        or (first == 100 and second >= 64 and second <= 127)
        or (first == 169 and second == 254)
        or (first == 172 and second >= 16 and second <= 31)
        or (first == 192 and (second == 0 or second == 168))
        or (first == 198 and (second == 18 or second == 19)) then
        return nil
    end
    return ip
end

local function safe_https_target(value)
    local url = trim(value or "") or ""
    if #url < 12 or #url > 1024 or url:find("%s") or url:sub(1, 8):lower() ~= "https://" then
        return nil
    end
    local authority = url:match("^https://([^/%?#]+)")
    if not authority or authority:find("@", 1, true) or authority:sub(1, 1) == "[" then return nil end
    local host, port = authority:match("^([^:]+):(%d+)$")
    if not host then
        if authority:find(":", 1, true) then return nil end
        host, port = authority, "443"
    end
    host = host:lower()
    port = tonumber(port)
    if not port or port < 1 or port > 65535
        or not host:match("^[a-z0-9%.%-]+$")
        or host == "localhost" or host:match("%.localhost$")
        or host:match("%.local$") or host:match("%.internal$")
        or host:match("^%d+$") or host:match("^0[xX]") then
        return nil
    end

    local address = public_ipv4(host)
    if not address then
        if valid_ipv4(host) then return nil end
        local nslookup = find_executable({ "/usr/bin/nslookup", "/bin/nslookup" })
        if not nslookup then return nil end
        local output, ok = capture(shell_quote(nslookup) .. " " .. shell_quote(host), 16384)
        if not ok then return nil end
        local after_name = false
        for line in output:gmatch("[^\r\n]+") do
            if line:match("^%s*Name%s*:") then
                after_name = true
            elseif after_name then
                local candidate = line:match("Address%s*%d*%s*:%s*([%d%.]+)")
                address = public_ipv4(candidate)
                if address then break end
            end
        end
        if not address then return nil end
    end
    return { url = url, host = host, port = port, address = address }
end

local function import_profile(installation, name, url)
    local target = safe_https_target(url)
    if not target then return nil, "Use a resolvable public HTTPS configuration URL" end
    name = valid_profile_name(name)
    if not name then return nil, "Use an ASCII .yaml or .yml file name" end
    local curl = find_executable({ "/usr/bin/curl", "/bin/curl", "/usr/sbin/curl" })
    if not curl then return nil, "curl is unavailable" end
    local temporary = "/tmp/mwef-nekocoffee-import." .. random_suffix() .. ".yaml"
    local command = shell_quote(curl)
        .. " -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 30 --max-filesize " .. tostring(MAX_PROFILE_SIZE)
        .. " --proto '=https' --proto-redir '=https'"
        .. " --resolve " .. shell_quote(target.host .. ":" .. tostring(target.port) .. ":" .. target.address)
        .. " -A " .. shell_quote("NekoCoffee/" .. VERSION)
        .. " -o " .. shell_quote(temporary) .. " " .. shell_quote(target.url)
    local result = os.execute(command .. " >/dev/null 2>&1")
    if not command_succeeded(result) then
        os.remove(temporary)
        return nil, "Unable to download the configuration URL"
    end
    local content = read_file(temporary, MAX_PROFILE_SIZE + 1)
    os.remove(temporary)
    return save_profile(installation, name, content)
end

local function validate_profile_with_core(installation, profile_path)
    local core = first_file({
        "/tmp/ShellCrash/CrashCore",
        "/tmp/ShellClash/CrashCore",
        installation.root .. "/CrashCore",
        installation.root .. "/CrashCore.raw"
    })
    local timeout = find_executable({ "/usr/bin/timeout", "/bin/timeout" })
    local busybox = find_executable({ "/bin/busybox", "/usr/bin/busybox" })
    if not core or (not timeout and not busybox) then return nil, "Configuration validator is unavailable" end
    local prefix = timeout and shell_quote(timeout) or (shell_quote(busybox) .. " timeout")
    local command = prefix .. " 20 " .. shell_quote(core)
        .. " -t -d " .. shell_quote(installation.root)
        .. " -f " .. shell_quote(profile_path)
    local result = os.execute(command .. " >/dev/null 2>&1")
    if not command_succeeded(result) then return nil, "Configuration failed the core validation check" end
    return true
end

local function replace_config_symlink(installation, target)
    local link = installation.root .. "/yamls/config.yaml"
    local temporary = installation.root .. "/yamls/.nekocoffee.config." .. random_suffix()
    local ln = find_executable({ "/bin/ln", "/usr/bin/ln" })
    if not ln then return nil, "ln is unavailable" end
    local result = os.execute(
        shell_quote(ln) .. " -s " .. shell_quote(target)
            .. " " .. shell_quote(temporary) .. " >/dev/null 2>&1"
    )
    if not command_succeeded(result) then
        os.remove(temporary)
        return nil, "Unable to prepare configuration switch"
    end
    if not os.rename(temporary, link) then
        os.remove(temporary)
        return nil, "Unable to activate configuration"
    end
    return true
end

local function switch_profile(installation, name)
    name = valid_profile_name(name)
    if not name then return nil, "Invalid configuration name" end
    local profile_path = installation.root .. "/providers/" .. name
    local lstat_ok, lstat = pcall(fs.lstat, profile_path)
    if not lstat_ok or not lstat or lstat.type ~= "reg" then
        return nil, "Configuration file not found or is not a regular file"
    end
    local content = read_file(profile_path, MAX_PROFILE_SIZE + 1)
    local valid, validation_error = profile_content_valid(content)
    if not valid then return nil, validation_error end
    local core_valid, core_error = validate_profile_with_core(installation, profile_path)
    if not core_valid then return nil, core_error end
    if active_profile_name(installation) == name then return true end

    local link = installation.root .. "/yamls/config.yaml"
    local readlink_ok, previous_target = pcall(fs.readlink, link)
    if not readlink_ok or not previous_target then
        return nil, "Active configuration is not a symbolic link; refusing to overwrite it"
    end
    local linked, link_error = replace_config_symlink(installation, "../providers/" .. name)
    if not linked then return nil, link_error end
    if installation.running then
        local restarted, restart_error = run_service(installation, "restart")
        if not restarted then
            local restored = replace_config_symlink(installation, previous_target)
            if restored then
                run_service(installation, "restart")
                return nil, "Restart failed; the previous configuration was restored: " .. restart_error
            end
            return nil, "Restart failed and the previous configuration could not be restored: " .. restart_error
        end
    end
    return true
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
    local ipv6_proxy = http.formvalue("ipv6Proxy") or ""
    local quic_proxy = http.formvalue("quicProxy") or ""
    local result, message = with_lock(function()
        return change_settings(detect_installation(), traffic_mode, dns_mode, ipv6_proxy, quic_proxy)
    end)
    if not result then return respond({ code = 500, message = message }, 500) end
    respond(collect_status())
end

local function handle_device_policy()
    if not require_post() then return end
    local allowed, grant_error = require_grants({
        "system.read", "filesystem.read", "filesystem.write", "service.control", "shell.execute"
    })
    if not allowed then return respond({ code = 403, message = grant_error }, 403) end
    local mode = http.formvalue("mode") or ""
    local macs = http.formvalue("macs") or ""
    local result, message = with_lock(function()
        return change_device_policy(detect_installation(), mode, macs)
    end)
    if not result then return respond({ code = 400, message = message }, 400) end
    respond(collect_status())
end

local function handle_profile_upload()
    if not require_post() then return end
    local allowed, grant_error = require_grants({
        "system.read", "filesystem.read", "filesystem.write"
    })
    if not allowed then return respond({ code = 403, message = grant_error }, 403) end

    local upload = { size = 0 }
    http.setfilehandler(function(meta, chunk, eof)
        if not meta or meta.name ~= "configFile" then return end
        if not upload.path then
            upload.originalName = meta.file
            upload.path = "/tmp/mwef-nekocoffee-upload." .. random_suffix() .. ".yaml"
            upload.handle = io.open(upload.path, "wb")
            if not upload.handle then upload.error = "Unable to create upload staging file" end
        end
        if chunk and #chunk > 0 then
            upload.size = upload.size + #chunk
            if upload.size > MAX_PROFILE_SIZE then
                upload.error = "Configuration file exceeds 2 MiB"
            elseif upload.handle and not upload.error then
                local ok, result = pcall(upload.handle.write, upload.handle, chunk)
                if not ok or not result then upload.error = "Unable to write upload staging file" end
            end
        end
        if eof and upload.handle then
            local flush_ok, flush_result = pcall(upload.handle.flush, upload.handle)
            local close_ok, close_result = pcall(upload.handle.close, upload.handle)
            upload.handle = nil
            if not flush_ok or not flush_result or not close_ok or not close_result then
                upload.error = "Unable to finish upload staging file"
            end
        end
    end)

    local requested_name = http.formvalue("profileName")
    http.formvalue("configFile")
    if upload.handle then pcall(upload.handle.close, upload.handle) end
    if upload.error or not upload.path then
        if upload.path then os.remove(upload.path) end
        return respond({ code = 400, message = upload.error or "No configuration file uploaded" }, 400)
    end
    local content = read_file(upload.path, MAX_PROFILE_SIZE + 1)
    os.remove(upload.path)
    local name = trim(requested_name or "")
    if not name or name == "" then name = upload.originalName end
    local result, message = with_lock(function()
        local installation = detect_installation()
        if not installation.detected then return nil, "ShellClash installation not found" end
        return save_profile(installation, name, content)
    end)
    if not result then return respond({ code = 400, message = message }, 400) end
    respond(collect_status())
end

local function handle_profile_import()
    if not require_post() then return end
    local allowed, grant_error = require_grants({
        "system.read", "filesystem.read", "filesystem.write", "network.client", "shell.execute"
    })
    if not allowed then return respond({ code = 403, message = grant_error }, 403) end
    local name = http.formvalue("profileName") or ""
    local url = http.formvalue("url") or ""
    local result, message = with_lock(function()
        local installation = detect_installation()
        if not installation.detected then return nil, "ShellClash installation not found" end
        return import_profile(installation, name, url)
    end)
    if not result then return respond({ code = 400, message = message }, 400) end
    respond(collect_status())
end

local function handle_profile_switch()
    if not require_post() then return end
    local allowed, grant_error = require_grants({
        "system.read", "filesystem.read", "filesystem.write", "network.client", "service.control", "shell.execute"
    })
    if not allowed then return respond({ code = 403, message = grant_error }, 403) end
    local name = http.formvalue("profileName") or ""
    local result, message = with_lock(function()
        local installation = detect_installation()
        if not installation.detected then return nil, "ShellClash installation not found" end
        return switch_profile(installation, name)
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
    if action == "device-policy" then return handle_device_policy() end
    if action == "ip-check" then return handle_ip_check() end
    if action == "profile-upload" then return handle_profile_upload() end
    if action == "profile-import" then return handle_profile_import() end
    if action == "profile-switch" then return handle_profile_switch() end
    respond({ code = 404, message = "Unknown action" }, 400)
end

