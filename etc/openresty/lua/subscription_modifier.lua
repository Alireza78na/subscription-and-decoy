local cjson = require "cjson"

-- اضافه کردن Seed رندوم و لیست User-Agent های استاندارد
math.randomseed(ngx.now() * 1000)
local standard_uas = {
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15"
}

-- مسیر فایل پیکربندی
local config_file = "/etc/openresty/config/subscription.json"

-- تابع خواندن پیکربندی از فایل JSON
local function load_config()
    local file = io.open(config_file, "r")
    if not file then
        ngx.log(ngx.ERR, "Cannot open config file: " .. config_file)
        return nil
    end

    local content = file:read("*all")
    file:close()

    local ok, config = pcall(cjson.decode, content)
    if not ok then
        ngx.log(ngx.ERR, "Invalid JSON in config file: " .. config_file)
        return nil
    end

    return config
end

-- بارگذاری پیکربندی
local config = load_config()
if not config then
    ngx.log(ngx.ERR, "Failed to load configuration, aborting")
    return
end

-- استخراج تنظیمات از JSON
local default_main = config.main_config
local alternatives = config.alternatives
local sos_enabled = config.sos.enabled
local sos_only_for_ws = config.sos.only_for_ws
local sos_configs = config.sos.configs

local data = ngx.arg[1]
if data and ngx.arg[2] == false then
    
    local current_uri = ngx.var.uri

    -- =========================================================
    -- حالت اول: سابسکریپشن /about (پردازش Base64 و ساختار Hybrid)
    -- =========================================================
    if current_uri:match("^/about") then
        local decoded_sub = ngx.decode_base64(data)
        if not decoded_sub then return end

        local configs = {}
        for config_line in decoded_sub:gmatch("[^\n]+") do
            table.insert(configs, config_line)
        end

        local has_ws = false
        local new_configs = {}

        for _, config_line in ipairs(configs) do
            
            if config_line:match("^vmess://") then
                local encoded_inner = config_line:match("vmess://(.+)")
                if encoded_inner then
                    local decoded_json = ngx.decode_base64(encoded_inner)
                    if decoded_json then
                        local json = cjson.decode(decoded_json)

                        if json.net == "ws" then
                            has_ws = true

                            if (not json.add or json.add == "" or json.add == "example.com") then
                                json.add = default_main.add
                            end
                            if (not json.host or json.host == "") then
                                json.host = default_main.host
                            end

                            local new_encoded_main = "vmess://" .. ngx.encode_base64(cjson.encode(json))
                            table.insert(new_configs, new_encoded_main)

                            for _, alt in ipairs(alternatives) do
                                if alt.enabled then
                                    local new_json = cjson.decode(cjson.encode(json))
                                    new_json.add = alt.add
                                    new_json.host = alt.host
                                    new_json.ps = new_json.ps .. alt.ps_suffix
                                    local new_encoded = "vmess://" .. ngx.encode_base64(cjson.encode(new_json))
                                    table.insert(new_configs, new_encoded)
                                end
                            end
                        else
                            table.insert(new_configs, config_line)
                        end
                    end
                end

            elseif config_line:match("^vless://") or config_line:match("^trojan://") then
                local protocol, uuid, server, port, path, query, hash = config_line:match("^([^:]+)://([^@]+)@([^:]+):(%d+)/?([^?#]*)%??([^#]*)#?(.*)$")
                
                if protocol and query and query:match("type=ws") then
                    has_ws = true
                    
                    local function update_query(q, key, val)
                        if q:match("(^|[&?])" .. key .. "=") then
                            q = q:gsub("(^|[&?])(" .. key .. "=)[^&]*", "%1%2" .. val)
                        else
                            q = q .. (q == "" and "" or "&") .. key .. "=" .. val
                        end
                        return q
                    end
                    
                    local function build_uri(p_server, p_query, p_hash)
                        local res = protocol .. "://" .. uuid .. "@" .. p_server .. ":" .. port
                        if path and path ~= "" then res = res .. "/" .. path end
                        if p_query and p_query ~= "" then res = res .. "?" .. p_query end
                        if p_hash and p_hash ~= "" then res = res .. "#" .. p_hash end
                        return res
                    end

                    local main_query = query
                    main_query = update_query(main_query, "host", default_main.host)
                    if main_query:match("security=tls") or main_query:match("security=reality") then
                        main_query = update_query(main_query, "sni", default_main.host)
                    end
                    table.insert(new_configs, build_uri(default_main.add, main_query, hash))

                    for _, alt in ipairs(alternatives) do
                        if alt.enabled then
                            local alt_query = query
                            alt_query = update_query(alt_query, "host", alt.host)
                            if alt_query:match("security=tls") or alt_query:match("security=reality") then
                                alt_query = update_query(alt_query, "sni", alt.host)
                            end
                            
                            local encoded_suffix = ngx.escape_uri(alt.ps_suffix)
                            local alt_hash = hash .. encoded_suffix
                            table.insert(new_configs, build_uri(alt.add, alt_query, alt_hash))
                        end
                    end
                else
                    table.insert(new_configs, config_line)
                end
            else
                table.insert(new_configs, config_line)
            end
        end

        if sos_enabled and sos_configs then
            if not sos_only_for_ws or has_ws then
                for _, sos_cfg in ipairs(sos_configs) do
                    table.insert(new_configs, sos_cfg)
                end
            end
        end

        if #new_configs > 0 then
            local new_sub = table.concat(new_configs, "\n")
            ngx.arg[1] = ngx.encode_base64(new_sub)
        end

    -- =========================================================
    -- حالت دوم: سابسکریپشن کلش/میهومو مسیر /api (Line-based Contextual Mutation)
    -- =========================================================
    elseif current_uri:match("^/api") then
        local lines = {}
        for line in data:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end

        local output_lines = {}
        local current_section = ""
        local proxy_lines = {}
        local created_proxy_names = {}

        local function flush_proxy_block()
            if #proxy_lines == 0 then return end
            
            -- بررسی وضعیت شبکه و استخراج نام اورجینال
            local is_ws = false
            local original_name = ""
            for _, pline in ipairs(proxy_lines) do
                if pline:match("^%s*network:%s*ws") or pline:match("^%s*type:%s*ws") then
                    is_ws = true
                end
                local n = pline:match("^%s*name:%s*(.+)") or pline:match("^%s*%-%s*name:%s*(.+)")
                if n then
                    original_name = n:gsub("^['\"]", ""):gsub("['\"]$", "")
                end
            end

            if is_ws and original_name ~= "" then
-- هسته جهش‌یافته هوشمند: جایگذاری مقادیر با حفظ ۱۰۰ درصدی ساختار کلش
                local function mutate_proxy(lines_to_mutate, new_name, new_server, new_host)
                    local mutated = {}
                    local ws_opts_indent = nil
                    local has_headers = false
                    local has_sni = false
                    local has_ua = false
                    local field_indent = "  "
                    
                    -- انتخاب یک User-Agent رندوم از لیست برای این کانفیگ
                    local random_ua = standard_uas[math.random(1, #standard_uas)]

                    -- اسکن اولیه بلاک برای پیدا کردن ساختارهای موجود
                    for _, line in ipairs(lines_to_mutate) do
                        if line:match("^%s*headers:") then has_headers = true end
                        if line:match("^%s*User%-Agent:") or line:match("^%s*user%-agent:") then has_ua = true end
                        if line:match("^%s*sni:") or line:match("^%s*%-%s*sni:") then has_sni = true end
                        local ind = line:match("^(%s*)[%w%-]+:")
                        if ind and #ind > 0 then field_indent = ind end
                    end

                    for _, line in ipairs(lines_to_mutate) do
                        local new_line = line
                        
                        -- تزریق امن با قرار دادن متون در کوتیشن (محافظت در برابر Mapping Error)
                        if line:match("^%s*%-%s*name:%s*") or line:match("^%s*name:%s*") then
                            local prefix = line:match("^(%s*%-%s*name:%s*)") or line:match("^(%s*name:%s*)")
                            new_line = prefix .. '"' .. new_name .. '"'
                        elseif line:match("^%s*%-%s*server:%s*") or line:match("^%s*server:%s*") then
                            local prefix = line:match("^(%s*%-%s*server:%s*)") or line:match("^(%s*server:%s*)")
                            new_line = prefix .. '"' .. new_server .. '"'
                        elseif line:match("^%s*%-%s*sni:%s*") or line:match("^%s*sni:%s*") then
                            local prefix = line:match("^(%s*%-%s*sni:%s*)") or line:match("^(%s*sni:%s*)")
                            new_line = prefix .. '"' .. new_host .. '"'
                        elseif line:match("^%s*Host:%s*") then
                            local prefix = line:match("^(%s*Host:%s*)")
                            new_line = prefix .. '"' .. new_host .. '"'
                        end
                        
                        table.insert(mutated, new_line)

                        -- تزریق هوشمند هدرها و User-Agent رندوم
                        if line:match("^%s*ws%-opts:%s*$") then
                            local base_indent = line:match("^(%s*)")
                            ws_opts_indent = base_indent .. "  "
                            -- اگر کلا هدر نداشت، بلاک هدرها رو می‌سازیم
                            if not has_headers then
                                table.insert(mutated, ws_opts_indent .. "headers:")
                                table.insert(mutated, ws_opts_indent .. "  Host: \"" .. new_host .. "\"")
                                table.insert(mutated, ws_opts_indent .. "  User-Agent: \"" .. random_ua .. "\"")
                            end
                        elseif line:match("^%s*headers:%s*$") then
                            -- اگر بلاک هدر وجود داشت اما یوزر ایجنت نداشت، اون رو دقیقاً زیر headers تزریق می‌کنیم
                            if not has_ua then
                                local h_indent = line:match("^(%s*)")
                                table.insert(mutated, h_indent .. "  User-Agent: \"" .. random_ua .. "\"")
                            end
                        end
                    end
                    
                    -- تزریق SNI در صورت فعال بودن TLS
                    if not has_sni then
                        local has_tls = false
                        for _, l in ipairs(lines_to_mutate) do
                            if l:match("tls:%s*true") or l:match("tls:%s*1") then has_tls = true break end
                        end
                        if has_tls then
                            table.insert(mutated, field_indent .. "sni: \"" .. new_host .. "\"")
                        end
                    end

                    return mutated
                end

                -- ۱. نسخه اصلی
                local main_mutated = mutate_proxy(proxy_lines, original_name, default_main.add, default_main.host)
                for _, ml in ipairs(main_mutated) do table.insert(output_lines, ml) end

                -- ۲. آلترناتیوها
                for _, alt in ipairs(alternatives) do
                    if alt.enabled then
                        local alt_name = original_name .. alt.ps_suffix
                        table.insert(created_proxy_names, alt_name)
                        local alt_mutated = mutate_proxy(proxy_lines, alt_name, alt.add, alt.host)
                        for _, ml in ipairs(alt_mutated) do table.insert(output_lines, ml) end
                    end
                end
            else
                for _, pline in ipairs(proxy_lines) do
                    table.insert(output_lines, pline)
                end
            end
            
            proxy_lines = {}
        end

        local i = 1
        while i <= #lines do
            local line = lines[i]

            if line:match("^proxies:") then
                flush_proxy_block()
                current_section = "proxies"
                table.insert(output_lines, line)
            elseif line:match("^proxy%-groups:") then
                flush_proxy_block()
                current_section = "proxy-groups"
                table.insert(output_lines, line)
            elseif line:match("^rules:") then
                flush_proxy_block()
                current_section = "rules"
                table.insert(output_lines, line)
            else
                if current_section == "proxies" then
                    -- تشخیص شروع بلاک یک پروکسی جدید در آرایه
                    if line:match("^%s*%-%s*[%w%-%_]+:") then
                        flush_proxy_block()
                        table.insert(proxy_lines, line)
                    else
                        if #proxy_lines > 0 then
                            table.insert(proxy_lines, line)
                        else
                            table.insert(output_lines, line)
                        end
                    end
                elseif current_section == "proxy-groups" then
                    table.insert(output_lines, line)
                    
                    -- تزریق نام‌های جدید درون گروه با تشخیص خودکار تورفتگی پنل شما
                    local group_proxies_indent = line:match("^(%s*)proxies:")
                    if group_proxies_indent then
                        local prefix = ""
                        for lookahead = i+1, i+5 do
                            if lines[lookahead] and lines[lookahead]:match("^%s*%-") then
                                prefix = lines[lookahead]:match("^(%s*%- )")
                                break
                            end
                        end
                        if prefix == "" then prefix = group_proxies_indent .. "  - " end

                        for _, new_p_name in ipairs(created_proxy_names) do
                            table.insert(output_lines, prefix .. '"' .. new_p_name .. '"')
                        end
                    end
                else
                    table.insert(output_lines, line)
                end
            end
            i = i + 1
        end
        flush_proxy_block()

        if #output_lines > 0 then
            ngx.arg[1] = table.concat(output_lines, "\n") .. "\n"
        end
    end
end
