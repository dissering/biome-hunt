local script = { actions = {}, state = {} }

local players_service = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local teleport_service = game:GetService("TeleportService")
local http_service = game:GetService("HttpService")

local local_player = players_service.LocalPlayer
local executor_env = type(getgenv) == "function" and getgenv() or _G

local config = {
    source_url = "https://raw.githubusercontent.com/dissering/biome-hunt/main/biome-hunt.lua",
    webhook_url = "",
    webhook_username = "Stella Biome Hunt",
    logo_url = "https://raw.githubusercontent.com/dissering/storage/main/stella/stella%20full.png",
    ping_everyone_biomes = { "Singularity", "Dreamspace", "Glitched" },
    report_all_servers = true,
    stay_on_rare = true,
    stay_on_merchant = true,
    merchant_mention_user_id = "",
    min_server_players = 0,
    settle_delay_range = { 3, 5 },
    stay_cap_seconds = 300,
    biome_wait_seconds = 30,
    request_timeout_seconds = 8,
}

local stored_config = executor_env.biome_hunt

if type(stored_config) == "table" then
    for key, value in pairs(stored_config) do
        config[key] = value
    end
end

local stored_webhook = executor_env.webhook

if type(stored_webhook) == "string" and stored_webhook ~= "" then
    config.webhook_url = stored_webhook
end

local all_biomes = {
    "Normal", "Rainy", "Snowy", "Windy", "SandStorm",
    "Dreamspace", "Glitched", "Blood Rain", "RedFullMoon", "Aurora",
    "Starfall", "Singularity", "RadiantForest", "Hell", "Null",
    "Heaven", "Corrupt", "Corruption", "Blazing Sun",
}

local common_biomes = { "Normal", "Rainy", "Snowy", "Windy", "SandStorm" }

local biome_colors = {
    Dreamspace = 0x7C4DFF,
    Glitched = 0x00E676,
    Singularity = 0xFFFFFF,
    Aurora = 0x00E5FF,
    Starfall = 0xFFD180,
    ["Blood Rain"] = 0xC62828,
    RedFullMoon = 0xD32F2F,
    Null = 0x37474F,
    Hell = 0xFF7043,
    Heaven = 0xFAFAFA,
    Corrupt = 0x8E24AA,
    Corruption = 0x8E24AA,
    RadiantForest = 0x66BB6A,
    ["Blazing Sun"] = 0xFFB300,
}

local generation = (tonumber(_G.__stella_biome_hunt_generation) or 0) + 1
_G.__stella_biome_hunt_generation = generation

script.state.visit_number = (tonumber(executor_env.__stella_biome_hunt_visits) or 0) + 1
executor_env.__stella_biome_hunt_visits = script.state.visit_number

script.state.merchant_name = nil
script.state.merchant_seen_at = {}
script.state.biome_cached = nil
script.state.biome_cached_at = 0

function script.actions.script_active()
    return _G.__stella_biome_hunt_generation == generation
end

function script.actions.biome_key(value)
    local key = tostring(value or ""):lower():gsub("[%s_%-]", "")

    return key
end

function script.actions.compact_text(value)
    local key = tostring(value or ""):lower():gsub("[%s_%-]", "")

    return key
end

function script.actions.canonical_biome(value)
    local key = script.actions.biome_key(value)

    if key == "" or key == "unknown" then
        return nil
    end

    for _, biome in ipairs(all_biomes) do
        if biome ~= "Any" and script.actions.biome_key(biome) == key then
            return biome
        end
    end

    return nil
end

function script.actions.wait_range(range)
    local low = tonumber(range[1]) or 3
    local high = tonumber(range[2]) or low + 3

    task.wait(low + math.random() * math.max(0, high - low))
end

function script.actions.get_request_function()
    local request_function = executor_env.request or executor_env.http_request
        or rawget(_G, "request") or rawget(_G, "http_request")

    if not request_function then
        local syn_table = executor_env.syn or rawget(_G, "syn")

        if type(syn_table) == "table" then
            request_function = syn_table.request
        end
    end

    if not request_function then
        local http_table = executor_env.http or rawget(_G, "http")

        if type(http_table) == "table" then
            request_function = http_table.request
        end
    end

    if not request_function and type(request) == "function" then
        request_function = request
    end

    return type(request_function) == "function" and request_function or nil
end

function script.actions.get_queue_function()
    local queue_function = executor_env.queue_on_teleport or executor_env.queueonteleport
        or rawget(_G, "queue_on_teleport") or rawget(_G, "queueonteleport")

    if not queue_function and type(queue_on_teleport) == "function" then
        queue_function = queue_on_teleport
    end

    return type(queue_function) == "function" and queue_function or nil
end

function script.actions.request_with_timeout(options, timeout)
    local request_function = script.actions.get_request_function()

    if not request_function then
        return false, nil
    end

    local finished = false
    local call_ok = false
    local response = nil

    task.spawn(function()
        local ok, call_response = pcall(request_function, options)

        call_ok = ok
        response = call_response
        finished = true
    end)

    local deadline = os.clock() + (timeout or config.request_timeout_seconds)

    while not finished and os.clock() < deadline do
        task.wait(0.1)
    end

    if not finished then
        return false, nil
    end

    return call_ok, response
end

function script.actions.get_replica_biome()
    local modules = replicated_storage:FindFirstChild("Modules")
    local utility = modules and modules:FindFirstChild("Utility")
    local replica_module = utility and utility:FindFirstChild("Replica")

    if not replica_module then
        return nil
    end

    local ok, replica = pcall(function()
        return require(replica_module).GetServerReplica()
    end)

    if ok and type(replica) == "table" and type(replica.Data) == "table" then
        return script.actions.canonical_biome(replica.Data.Biome or replica.Data.BiomeName)
    end

    return nil
end

function script.actions.get_server_info_biome()
    local server_info = replicated_storage:FindFirstChild("ServerInfo")

    if not server_info then
        return nil
    end

    return script.actions.canonical_biome(server_info:GetAttribute("CurrentBiome"))
end

function script.actions.get_ui_biome()
    local player_gui = local_player:FindFirstChild("PlayerGui")
    local main_interface = player_gui and player_gui:FindFirstChild("MainInterface")

    if not main_interface then
        return nil
    end

    for _, node in ipairs(main_interface:GetDescendants()) do
        if (node:IsA("TextLabel") or node:IsA("TextButton")) and node.Text and node.Text ~= "" then
            local bracket = node.Text:match("^%s*%[%s*(.-)%s*%]%s*$")
            local biome = bracket and script.actions.canonical_biome(bracket)

            if biome then
                return biome
            end
        end
    end

    return nil
end

function script.actions.get_current_biome()
    if script.state.biome_cached_at > 0 and os.clock() - script.state.biome_cached_at < 1 then
        return script.state.biome_cached or "Unknown"
    end

    local value = script.actions.get_replica_biome()
        or script.actions.get_server_info_biome()
        or script.actions.get_ui_biome()

    if value then
        script.state.biome_cached = value
        script.state.biome_cached_at = os.clock()
    end

    return value or "Unknown"
end

function script.actions.is_ping_biome(biome)
    local key = script.actions.biome_key(biome)

    for _, ping_biome in ipairs(config.ping_everyone_biomes) do
        if script.actions.biome_key(ping_biome) == key then
            return true
        end
    end

    return false
end

function script.actions.is_notable_biome(biome)
    if script.actions.canonical_biome(biome) == nil then
        return tostring(biome or "") ~= "" and biome ~= "Unknown"
    end

    local key = script.actions.biome_key(biome)

    for _, common in ipairs(common_biomes) do
        if script.actions.biome_key(common) == key then
            return false
        end
    end

    return true
end

function script.actions.is_stay_biome(biome)
    if script.actions.canonical_biome(biome) == nil then
        return false
    end

    local key = script.actions.biome_key(biome)

    for _, common in ipairs(common_biomes) do
        if script.actions.biome_key(common) == key then
            return false
        end
    end

    return true
end

function script.actions.get_biome_color(biome)
    return biome_colors[script.actions.canonical_biome(biome) or tostring(biome)] or 0x4FC3F7
end

function script.actions.normalize_merchant_name(value)
    local key = script.actions.compact_text(value)

    if key == "" then
        return nil
    end

    if key:match("^rin") or key:find("rinmerchant", 1, true) then
        return "Rin"
    elseif key:match("^mari") or key:find("marimerchant", 1, true) then
        return "Mari"
    elseif key:match("^jester") then
        return "Jester"
    end

    return tostring(value)
end

function script.actions.parse_merchant_name(payload)
    if type(payload) ~= "table" then
        return nil
    end

    for _, field in ipairs({ "merchant_name", "merchantName", "MerchantName", "merchant", "Merchant", "name", "Name" }) do
        local value = payload[field]

        if type(value) == "string" and value ~= "" then
            return value
        end
    end

    return nil
end

function script.actions.mark_merchant_spawned(raw_name)
    local merchant_name = script.actions.normalize_merchant_name(raw_name)
        or script.state.merchant_name or "Unknown merchant"
    local key = script.actions.compact_text(merchant_name)
    local now = os.clock()

    script.state.merchant_name = merchant_name

    if script.state.merchant_seen_at[key] and now - script.state.merchant_seen_at[key] < 30 then
        return
    end

    script.state.merchant_seen_at[key] = now
    script.actions.notify_merchant(merchant_name)
end

function script.actions.handle_merchant_remote(event_name, ...)
    if event_name == "MerchantDespawned" then
        script.state.merchant_name = nil
        return
    end

    local arguments = table.pack(...)
    local raw_name = script.actions.parse_merchant_name(arguments[1])

    for index = 2, arguments.n do
        local value = arguments[index]

        if type(value) == "table" then
            raw_name = raw_name or script.actions.parse_merchant_name(value)
        end
    end

    if event_name == "MerchantSpawned" then
        script.actions.mark_merchant_spawned(raw_name)
    elseif raw_name then
        script.state.merchant_name = script.actions.normalize_merchant_name(raw_name)
            or script.state.merchant_name
    end
end

function script.actions.consider_merchant_instance(instance)
    if not instance or not instance.Parent then
        return
    end

    local key = script.actions.compact_text(instance.Name)

    if key == "" then
        return
    end

    local looks_like_merchant = key:find("merchant", 1, true)
        or key:match("^rin") or key:match("^mari") or key:match("^jester")

    if looks_like_merchant then
        script.actions.mark_merchant_spawned(instance.Name)
    end
end

function script.actions.start_merchant_watcher()
    task.spawn(function()
        local bound = {}
        local retry_until = os.clock() + 60

        while script.actions.script_active() and os.clock() < retry_until do
            local remote_root = replicated_storage:FindFirstChild("Remote")
            local merchant_root = remote_root and remote_root:FindFirstChild("Merchant")

            if merchant_root then
                for _, event_name in ipairs({ "MerchantSpawned", "MerchantOpened", "MerchantDespawned" }) do
                    local event = merchant_root:FindFirstChild(event_name)

                    if event and event:IsA("RemoteEvent") and not bound[event] then
                        local ok, connection = pcall(function()
                            return event.OnClientEvent:Connect(function(...)
                                script.actions.handle_merchant_remote(event_name, ...)
                            end)
                        end)

                        if ok and connection then
                            bound[event] = true
                        end
                    end
                end
            end

            local bound_count = 0

            for _ in pairs(bound) do
                bound_count = bound_count + 1
            end

            if bound_count >= 3 then
                break
            end

            task.wait(1)
        end
    end)

    for _, child in ipairs(workspace:GetChildren()) do
        script.actions.consider_merchant_instance(child)
    end

    workspace.ChildAdded:Connect(function(child)
        task.wait(0.5)
        script.actions.consider_merchant_instance(child)
    end)
end

function script.actions.get_server_join_link(job_id)
    return "https://www.roblox.com/games/start?placeId=" .. tostring(game.PlaceId)
        .. "&gameInstanceId=" .. tostring(job_id or game.JobId)
end

function script.actions.get_join_button(job_id)
    return { {
        type = 1,
        components = { {
            type = 2,
            style = 5,
            label = "Join Server",
            url = script.actions.get_server_join_link(job_id),
        } },
    } }
end

function script.actions.get_players_field()
    return tostring(#players_service:GetPlayers())
end

function script.actions.send_webhook(payload, allow_retry)
    if config.webhook_url == "" then
        print("[stella biome hunt] no webhook url set (getgenv().webhook) — skipping alert")
        return false
    end

    local ok, response = script.actions.request_with_timeout({
        Url = config.webhook_url,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = http_service:JSONEncode(payload),
    })

    if not ok or type(response) ~= "table" then
        print("[stella biome hunt] webhook request failed or timed out")
        return false
    end

    local status = tonumber(response.StatusCode) or 0

    if status == 400 and payload.components and allow_retry ~= false then
        payload.components = nil

        return script.actions.send_webhook(payload, false)
    end

    if status == 429 and allow_retry ~= false then
        local retry_after = 3

        pcall(function()
            local decoded = http_service:JSONDecode(response.Body)

            retry_after = math.min(30, tonumber(decoded.retry_after) or 3)
        end)

        print("[stella biome hunt] webhook rate limited, retrying in " .. tostring(retry_after) .. "s")
        task.wait(retry_after + 1)

        return script.actions.send_webhook(payload, false)
    end

    if status < 200 or status >= 300 then
        print("[stella biome hunt] webhook status " .. tostring(status) .. " " .. tostring(response.Body):sub(1, 120))
        return false
    end

    return true
end

function script.actions.notify_biome(biome)
    local ping_tier = script.actions.is_ping_biome(biome)
    local notable = script.actions.is_notable_biome(biome)

    if not ping_tier and not notable and not config.report_all_servers then
        return
    end

    local description = "**" .. biome .. "** is active in this server."

    if script.state.merchant_name then
        description = description .. "\n**" .. script.state.merchant_name .. "** merchant is here right now."
    end

    if ping_tier then
        description = description .. "\nRare biome — join before it ends!"
    end

    local payload = {
        username = config.webhook_username,
        avatar_url = config.logo_url,
        embeds = { {
            title = "Biome Hunt • " .. biome,
            color = script.actions.get_biome_color(biome),
            description = description,
            fields = {
                { name = "Biome", value = "**" .. biome .. "**", inline = true },
                { name = "Merchant", value = script.state.merchant_name or "None", inline = true },
                { name = "Players", value = script.actions.get_players_field(), inline = true },
            },
            thumbnail = { url = config.logo_url },
            footer = {
                text = "Stella • Sol's RNG • visit #" .. tostring(script.state.visit_number),
                icon_url = config.logo_url,
            },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
        components = script.actions.get_join_button(game.JobId),
    }

    if ping_tier then
        payload.content = "@everyone"
        payload.allowed_mentions = { parse = { "everyone" } }
    end

    local delivered = script.actions.send_webhook(payload, true)

    print("[stella biome hunt] biome " .. biome .. (delivered and " reported" or " report failed"))
end

function script.actions.notify_merchant(merchant_name)
    local biome = script.actions.get_current_biome()
    local mention_user_id = tostring(config.merchant_mention_user_id or ""):match("%d+")

    local payload = {
        username = config.webhook_username,
        avatar_url = config.logo_url,
        embeds = { {
            title = "Merchant Spawned • " .. merchant_name,
            color = 0xFFD54F,
            description = "**" .. merchant_name .. "** just spawned"
                .. (biome ~= "Unknown" and (" in a **" .. biome .. "** server") or "") .. ".",
            fields = {
                { name = "Merchant", value = "**" .. merchant_name .. "**", inline = true },
                { name = "Biome", value = biome, inline = true },
                { name = "Players", value = script.actions.get_players_field(), inline = true },
            },
            thumbnail = { url = config.logo_url },
            footer = {
                text = "Stella • Sol's RNG • visit #" .. tostring(script.state.visit_number),
                icon_url = config.logo_url,
            },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
        components = script.actions.get_join_button(game.JobId),
    }

    if mention_user_id then
        payload.content = "<@" .. mention_user_id .. ">"
        payload.allowed_mentions = { users = { mention_user_id } }
    end

    local delivered = script.actions.send_webhook(payload, true)

    print("[stella biome hunt] merchant " .. merchant_name .. (delivered and " reported" or " report failed"))
end

function script.actions.fetch_server_candidates()
    local request_function = script.actions.get_request_function()

    if not request_function then
        print("[stella biome hunt] no http request function — using matchmaking fallback")
        return {}
    end

    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=2&limit=100",
        game.PlaceId)

    local ok, response = script.actions.request_with_timeout({ Url = url, Method = "GET" })

    if not ok then
        print("[stella biome hunt] server list request failed or timed out — using matchmaking fallback")
        return {}
    end

    if type(response) ~= "table" or (tonumber(response.StatusCode) or 0) ~= 200 then
        local status = type(response) == "table" and tostring(response.StatusCode) or "?"
        local body = type(response) == "table" and tostring(response.Body):sub(1, 120) or ""

        print("[stella biome hunt] server list status " .. status .. " " .. body)
        return {}
    end

    local ok_decode, data = pcall(function()
        return http_service:JSONDecode(response.Body)
    end)

    if not ok_decode or type(data) ~= "table" or type(data.data) ~= "table" then
        print("[stella biome hunt] server list response unparsable")
        return {}
    end

    local candidates = {}

    for _, server in ipairs(data.data) do
        if type(server) == "table" and server.id ~= game.JobId
            and (tonumber(server.playing) or 0) >= config.min_server_players
            and (tonumber(server.playing) or 0) < (tonumber(server.maxPlayers) or 12) then
            table.insert(candidates, server.id)
        end
    end

    return candidates
end

function script.actions.queue_rejoin()
    local queue_function = script.actions.get_queue_function()

    if not queue_function then
        print("[stella biome hunt] queue_on_teleport unavailable — hunting stops at this hop")
        return
    end

    local queued_source = 'if not game:IsLoaded() then game.Loaded:Wait() end '
        .. 'print("[stella biome hunt] rejoin loader fired") '
        .. 'loadstring(game:HttpGet("' .. config.source_url .. '"))()'

    local ok = pcall(queue_function, queued_source)

    print("[stella biome hunt] rejoin queue " .. (ok and "armed" or "failed"))
end

function script.actions.hop()
    script.actions.queue_rejoin()

    local candidates = script.actions.fetch_server_candidates()
    print("[stella biome hunt] hopping: " .. tostring(#candidates) .. " candidate servers")

    for attempt = 1, 3 do
        if #candidates == 0 then
            break
        end

        local target_job_id = candidates[math.random(1, #candidates)]
        local ok, err = pcall(function()
            teleport_service:TeleportToPlaceInstance(game.PlaceId, target_job_id, local_player)
        end)

        if ok then
            print("[stella biome hunt] teleport requested to " .. target_job_id)

            task.wait(12)
            return true
        end

        print("[stella biome hunt] teleport attempt " .. tostring(attempt) .. " failed: " .. tostring(err))
        task.wait(2)
    end

    local ok, err = pcall(function()
        teleport_service:Teleport(game.PlaceId, local_player)
    end)

    if ok then
        print("[stella biome hunt] fallback teleport requested")
        task.wait(12)
        return true
    end

    print("[stella biome hunt] fallback teleport failed: " .. tostring(err) .. " — retrying soon")
    task.wait(5)

    return false
end

function script.actions.wait_for_biome(timeout)
    local deadline = os.clock() + (timeout or config.biome_wait_seconds)

    while os.clock() < deadline and script.actions.script_active() do
        local biome = script.actions.get_current_biome()

        if biome ~= "Unknown" then
            print("[stella biome hunt] biome detected: " .. biome)
            return biome
        end

        task.wait(0.75)
    end

    print("[stella biome hunt] biome not detected — hopping anyway")
    return "Unknown"
end

function script.actions.stay_while_special(start_biome)
    local biome = start_biome
    local deadline = os.clock() + config.stay_cap_seconds

    print("[stella biome hunt] staying in server for " .. biome
        .. (script.state.merchant_name and " + merchant" or ""))

    while script.actions.script_active() and os.clock() < deadline do
        task.wait(1)

        local latest = script.actions.get_current_biome()

        if latest ~= "Unknown" and latest ~= biome then
            biome = latest
            script.actions.notify_biome(biome)
        end

        local special_biome = script.actions.is_ping_biome(biome)
            or script.actions.is_stay_biome(biome)
        local merchant_here = script.state.merchant_name ~= nil and config.stay_on_merchant

        if not special_biome and not merchant_here then
            break
        end
    end

    print("[stella biome hunt] stay finished — hopping on")
    script.actions.wait_range(config.settle_delay_range)

    return script.actions.get_current_biome()
end

function script.actions.looks_like_sols()
    if replicated_storage:FindFirstChild("ServerInfo") then
        return true
    end

    local remote_root = replicated_storage:FindFirstChild("Remote")

    if remote_root and remote_root:FindFirstChild("Merchant") then
        return true
    end

    local player_gui = local_player:FindFirstChild("PlayerGui")

    if player_gui and player_gui:FindFirstChild("MainInterface") then
        return true
    end

    return false
end

function script.actions.run()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    print("[stella biome hunt] starting (visit #" .. tostring(script.state.visit_number) .. ")")

    if not script.actions.looks_like_sols() then
        task.wait(8)

        if not script.actions.looks_like_sols() then
            print("[stella biome hunt] this does not look like Sol's RNG — stopping")
            return
        end
    end

    script.actions.start_merchant_watcher()

    local biome = script.actions.wait_for_biome()
    local last_alerted = nil

    while script.actions.script_active() do
        local current = script.actions.get_current_biome()

        if current ~= "Unknown" then
            biome = current
        end

        if biome ~= "Unknown" and biome ~= last_alerted then
            script.actions.notify_biome(biome)
            last_alerted = biome
        end

        local ping_tier = script.actions.is_ping_biome(biome)
        local stay_tier = script.actions.is_stay_biome(biome)
        local merchant_here = script.state.merchant_name ~= nil

        local should_stay = ((ping_tier or stay_tier) and config.stay_on_rare)
            or (merchant_here and config.stay_on_merchant)

        print("[stella biome hunt] cycle: biome=" .. tostring(biome)
            .. " merchant=" .. tostring(script.state.merchant_name or "none")
            .. " stay=" .. tostring(should_stay))

        if should_stay then
            biome = script.actions.stay_while_special(biome)
        else
            script.actions.wait_range(config.settle_delay_range)
        end

        if script.actions.script_active() then
            script.actions.hop()
        end
    end
end

script.actions.run()
