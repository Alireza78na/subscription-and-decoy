local cjson = require "cjson"

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
local sos_only_for_ws = config.sos.only_for_ws  -- جدید: چک شرط WS
-- تابع اصلی ویرایش بدنه
local data = ngx.arg[1]  -- بدنه پاسخ از پنل (base64 لایه دوم)
if data and ngx.arg[2] == false then  -- فقط اگر بدنه کامل باشد
    -- Decode لایه دوم (کل subscription)
    local decoded_sub = ngx.decode_base64(data)
    if not decoded_sub then return end

    -- تقسیم به کانفیگ‌های فردی (جدا شده با \n)
    local configs = {}
    for config_line in decoded_sub:gmatch("[^\n]+") do
        table.insert(configs, config_line)
    end

    -- فلگ برای چک وجود VMess WS (جدید: برای شرط SOS)
    local has_ws = false

    -- پردازش شرطی کانفیگ‌ها
    local new_configs = {}
    for _, config_line in ipairs(configs) do
        if config_line:match("^vmess://") then
            -- استخراج base64 داخلی برای VMess
            local encoded_inner = config_line:match("vmess://(.+)")
            if encoded_inner then
                local decoded_json = ngx.decode_base64(encoded_inner)
                if decoded_json then
                    local json = cjson.decode(decoded_json)

                    if json.net == "ws" then
                        has_ws = true  -- فلگ: VMess WS پیدا شد (جدید)

                        -- VMess WS: ویرایش اصلی
                        if (not json.add or json.add == "" or json.add == "example.com") then
                            json.add = default_main.add
                        end
                        if (not json.host or json.host == "") then
                            json.host = default_main.host
                        end

                        -- اضافه کردن نسخه ویرایش‌شده اصلی
                        local new_encoded_main = "vmess://" .. ngx.encode_base64(cjson.encode(json))
                        table.insert(new_configs, new_encoded_main)

                        -- ساخت کانفیگ‌های جدید (فقط آنهایی که فعال هستند)
                        for _, alt in ipairs(alternatives) do
                            if alt.enabled then
                                local new_json = cjson.decode(cjson.encode(json))  -- کپی عمیق
                                new_json.add = alt.add
                                new_json.host = alt.host
                                new_json.ps = new_json.ps .. alt.ps_suffix
                                local new_encoded = "vmess://" .. ngx.encode_base64(cjson.encode(new_json))
                                table.insert(new_configs, new_encoded)
                            end
                        end
                    else
                        -- VMess غیر-WS: بدون تغییر
                        table.insert(new_configs, config_line)
                    end
                end
            end
        else
            -- هر چیز غیر VMess: بدون تغییر
            table.insert(new_configs, config_line)
        end
    end

    -- اضافه کردن کانفیگ‌های SOS اگر فعال باشد (جدید: شرط only_for_ws و آرایه configs)
    if sos_enabled then
        if not sos_only_for_ws or has_ws then  -- فقط اگر only_for_ws false باشه یا WS وجود داشته باشه
            for _, sos_cfg in ipairs(sos_configs) do
                table.insert(new_configs, sos_cfg)
            end
        end
    end

    -- جمع‌آوری و encode لایه دوم
    if #new_configs > 0 then
        local new_sub = table.concat(new_configs, "\n")
        ngx.arg[1] = ngx.encode_base64(new_sub)
    end
end
