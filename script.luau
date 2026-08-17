local script = { actions = {}, state = {} }

local players_service = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local teleport_service = game:GetService("TeleportService")
local http_service = game:GetService("HttpService")

local local_player = players_service.LocalPlayer
local executor_env = type(getgenv) == "function" and getgenv() or _G

-- // the only setting: fill this in, or set getgenv().webhook before running
local webhook = ""

-- // where this script lives; used to re-queue itself after every server hop
local source_url = "https://raw.githubusercontent.com/dissering/biome-hunt/main/script.luau"

local webhook_username = "Biome Hunt"
local hosted_by = local_player.Name
local hosted_avatar = "https://www.roblox.com/headshot-thumbnail/image?userId="
    .. tostring(local_player.UserId) .. "&width=420&height=420&format=png"
local biome_wait_seconds = 30
local request_timeout_seconds = 8

local stored_webhook = executor_env.webhook

if type(stored_webhook) == "string" and stored_webhook ~= "" then
    webhook = stored_webhook
end

-- // double execution protection: a live hunt updates this heartbeat, so a
-- // second execution inside the window stops itself instead of doubling up
local last_heartbeat = tonumber(executor_env.__stella_biome_hunt_heartbeat) or 0

if os.time() - last_heartbeat < 30 then
    print("[biome hunt] already running — stopping this extra execution")
    return
end

-- // every biome the hunter recognizes; unrecognized names still get reported
local all_biomes = {
    "Normal", "Rainy", "Snowy", "Windy", "SandStorm",
    "Dreamspace", "Glitched", "Blood Rain", "RedFullMoon", "Aurora",
    "Starfall", "Singularity", "RadiantForest", "Hell", "Null",
    "Heaven", "Corrupt", "Corruption", "Blazing Sun", "Cyberspace",
}

local generation = (tonumber(_G.__stella_biome_hunt_generation) or 0) + 1
_G.__stella_biome_hunt_generation = generation

script.state.visit_number = (tonumber(executor_env.__stella_biome_hunt_visits) or 0) + 1
executor_env.__stella_biome_hunt_visits = script.state.visit_number

script.state.merchant_name = nil
script.state.merchant_stock = nil
script.state.merchant_seen_at = {}
script.state.biome_cached = nil
script.state.biome_cached_at = 0
script.state.server_replica = nil
script.state.last_alert_biome = nil
script.state.last_alert_at = 0
script.state.last_alert_signature = nil
script.state.notify_busy = false

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

function script.actions.settle_wait()
    task.wait(3 + math.random() * 2)
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

    local deadline = os.clock() + (timeout or request_timeout_seconds)

    while not finished and os.clock() < deadline do
        task.wait(0.1)
    end

    if not finished then
        return false, nil
    end

    return call_ok, response
end

-- // GetServerReplica can yield forever, so it only ever runs on its own
-- // thread here and detection just reads whatever it managed to cache
function script.actions.start_replica_loader()
    task.spawn(function()
        while script.actions.script_active() do
            if type(script.state.server_replica) ~= "table" then
                local ok, result = pcall(function()
                    local modules = replicated_storage:FindFirstChild("Modules")
                    local utility = modules and modules:FindFirstChild("Utility")
                    local replica_module = utility and utility:FindFirstChild("Replica")

                    if not replica_module then
                        return nil
                    end

                    return require(replica_module).GetServerReplica()
                end)

                if ok and type(result) == "table" and type(result.Data) == "table" then
                    script.state.server_replica = result
                end
            end

            task.wait(2)
        end
    end)
end

function script.actions.get_replica_biome()
    local replica = script.state.server_replica

    if type(replica) == "table" and type(replica.Data) == "table" then
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

    -- // UI label first: on event maps the ServerInfo "CurrentBiome" attribute
    -- // stays at its stale default (e.g. "Normal") while the real biome is
    -- // only shown in the UI (e.g. "SAND STORM")
    local value = script.actions.get_ui_biome()
        or script.actions.get_replica_biome()
        or script.actions.get_server_info_biome()

    if value then
        script.state.biome_cached = value
        script.state.biome_cached_at = os.clock()
    end

    return value or "Unknown"
end

-- // built-in @everyone pings: Singularity, Dreamspace, Glitched, Cyberspace
function script.actions.is_ping_biome(biome)
    local key = script.actions.biome_key(biome)

    return key == "singularity" or key == "dreamspace"
        or key == "glitched" or key == "cyberspace"
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

function script.actions.get_field(payload, field_names)
    if type(payload) ~= "table" then
        return nil
    end

    for _, field_name in ipairs(field_names) do
        local value = payload[field_name]

        if value ~= nil then
            return value
        end
    end

    return nil
end

function script.actions.parse_quantity(value, depth)
    if type(value) == "number" then
        return value
    end

    if type(value) == "string" then
        return tonumber(value)
    end

    if type(value) ~= "table" or (tonumber(depth) or 0) > 3 then
        return nil
    end

    local direct = script.actions.get_field(value, {
        "StockLeft", "stock_left", "stockLeft", "Stock", "stock",
        "Quantity", "quantity", "Remaining", "remaining",
    })

    if direct ~= nil then
        return script.actions.parse_quantity(direct, (tonumber(depth) or 0) + 1)
    end

    for _, field_name in ipairs({ "result", "Result", "data", "Data", "value", "Value" }) do
        local nested = value[field_name]

        if nested ~= nil then
            local parsed = script.actions.parse_quantity(nested, (tonumber(depth) or 0) + 1)

            if parsed ~= nil then
                return parsed
            end
        end
    end

    return nil
end

function script.actions.parse_boolean(value)
    if type(value) == "boolean" then
        return value
    end

    if type(value) == "number" then
        return value ~= 0
    end

    if type(value) == "string" then
        local key = value:lower()

        if key == "true" or key == "1" or key == "yes" then
            return true
        elseif key == "false" or key == "0" or key == "no" then
            return false
        end
    end

    return nil
end

function script.actions.collect_product_sources(payload, output, visited, depth)
    if type(payload) ~= "table" or visited[payload] or (tonumber(depth) or 0) > 5 then
        return
    end

    visited[payload] = true

    local products = script.actions.get_field(payload, {
        "product_list", "productList", "Products", "products", "Items", "items",
    })

    if type(products) == "table" then
        table.insert(output, products)

        return
    end

    for _, nested in pairs(payload) do
        if type(nested) == "table" then
            script.actions.collect_product_sources(nested, output, visited, (tonumber(depth) or 0) + 1)
        end
    end
end

function script.actions.format_stock_text(records)
    local in_stock = {}
    local sold_out = {}

    for _, record in ipairs(records) do
        if record.available then
            local suffix = ""

            if record.quantity ~= nil and record.quantity ~= math.huge then
                suffix = " x" .. tostring(math.floor(record.quantity))
            end

            table.insert(in_stock, record.name .. suffix)
        else
            table.insert(sold_out, "~~" .. record.name .. "~~")
        end
    end

    local parts = {}

    if #in_stock > 0 then
        table.insert(parts, table.concat(in_stock, ", "))
    end

    if #sold_out > 0 then
        table.insert(parts, table.concat(sold_out, ", "))
    end

    if #parts == 0 then
        return nil
    end

    local text = table.concat(parts, "\n")

    if #text > 900 then
        text = text:sub(1, 897) .. "..."
    end

    return text
end

-- // stock rides along the merchant remotes (same parse as the main Sol's script)
function script.actions.update_merchant_stock(...)
    local arguments = table.pack(...)
    local sources = {}

    for index = 1, arguments.n do
        script.actions.collect_product_sources(arguments[index], sources, {}, 0)
    end

    if #sources == 0 then
        return
    end

    local records = {}

    for _, source in ipairs(sources) do
        for product_key, product in pairs(source) do
            if #records >= 40 then
                break
            end

            if type(product) == "table" then
                local name = script.actions.get_field(product, {
                    "ProductDisplayName", "productDisplayName", "ProductName", "productName",
                    "DisplayName", "displayName", "Name", "name",
                }) or product_key
                local quantity = script.actions.parse_quantity(product, 0)
                local sold_out = script.actions.parse_boolean(script.actions.get_field(product, {
                    "SoldOut", "sold_out", "soldOut", "IsSoldOut",
                }))
                local locked = script.actions.parse_boolean(script.actions.get_field(product, {
                    "Locked", "locked", "IsLocked", "isLocked",
                }))
                local available = script.actions.parse_boolean(script.actions.get_field(product, {
                    "Available", "available", "IsAvailable", "is_available",
                }))

                if locked == true or sold_out == true then
                    available = false
                elseif quantity ~= nil then
                    available = quantity == math.huge or quantity > 0
                elseif available == nil then
                    available = true
                end

                table.insert(records, {
                    name = tostring(name),
                    quantity = quantity,
                    available = available == true,
                })
            elseif type(product) == "string" then
                table.insert(records, { name = product, quantity = nil, available = true })
            end
        end

        if #records > 0 then
            break
        end
    end

    if #records == 0 then
        return
    end

    script.state.merchant_stock = script.actions.format_stock_text(records)
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
    script.state.merchant_stock = nil

    -- // merchant spawns re-send the one combined alert (never a second
    -- // message type); notify_biome itself waits for the stock to land
    task.delay(1, function()
        if not script.actions.script_active() then
            return
        end

        if script.state.merchant_name ~= merchant_name then
            return
        end

        script.actions.notify_biome(script.actions.get_current_biome(), true)
    end)
end

function script.actions.handle_merchant_remote(event_name, ...)
    if event_name == "MerchantDespawned" then
        script.state.merchant_name = nil
        script.state.merchant_stock = nil
        return
    end

    script.actions.update_merchant_stock(...)

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

    if instance.ClassName ~= "Model" then
        return
    end

    -- // exact NPC names only: loose prefix matching reports player aura
    -- // models like "mariotendo666Aura" as merchants
    local key = script.actions.compact_text(instance.Name)

    if key ~= "rin" and key ~= "mari" and key ~= "jester" then
        return
    end

    -- // merchant NPCs are Model + Humanoid + Torso with a ProximityPrompt;
    -- // player characters carry HumanoidRootPart instead, auras carry neither
    if not instance:FindFirstChildOfClass("Humanoid") then
        return
    end

    local torso = instance:FindFirstChild("Torso")

    if not torso or not torso:FindFirstChildOfClass("ProximityPrompt") then
        return
    end

    script.actions.mark_merchant_spawned(instance.Name)
end

function script.actions.start_merchant_watcher()
    task.spawn(function()
        local bound = {}
        local retry_until = os.clock() + 60

        while script.actions.script_active() and os.clock() < retry_until do
            local remote_root = replicated_storage:FindFirstChild("Remote")
            local merchant_root = remote_root and remote_root:FindFirstChild("Merchant")

            if merchant_root then
                for _, event_name in ipairs({ "MerchantSpawned", "MerchantOpened", "FetchProducts", "ProductQuantityUpdated", "MerchantDespawned" }) do
                    local event = merchant_root:FindFirstChild(event_name)

                    -- // bind anything with OnClientEvent -- low-level executors
                    -- // can misreport IsA, and a pcall Connect covers the rest
                    if event and not bound[event] then
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

            if bound_count >= 5 then
                break
            end

            task.wait(1)
        end
    end)

    for _, child in ipairs(workspace:GetChildren()) do
        script.actions.consider_merchant_instance(child)
    end

    workspace.ChildAdded:Connect(function(child)
        if not script.actions.script_active() then
            return
        end

        task.wait(0.5)
        script.actions.consider_merchant_instance(child)
    end)
end

function script.actions.get_server_join_link(job_id)
    return "https://www.roblox.com/games/start?placeId=" .. tostring(game.PlaceId)
        .. "&gameInstanceId=" .. tostring(job_id or game.JobId)
end

function script.actions.get_players_field()
    return tostring(#players_service:GetPlayers())
end

function script.actions.send_webhook(payload, allow_retry)
    if webhook == "" then
        print("[biome hunt] no webhook url set (getgenv().webhook) — skipping alert")
        return false
    end

    local ok, response = script.actions.request_with_timeout({
        Url = webhook,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = http_service:JSONEncode(payload),
    })

    if not ok or type(response) ~= "table" then
        print("[biome hunt] webhook request failed or timed out")
        return false
    end

    local status = tonumber(response.StatusCode) or 0

    if status == 429 and allow_retry ~= false then
        local retry_after = 3

        pcall(function()
            local decoded = http_service:JSONDecode(response.Body)

            retry_after = math.min(30, tonumber(decoded.retry_after) or 3)
        end)

        print("[biome hunt] webhook rate limited, retrying in " .. tostring(retry_after) .. "s")
        task.wait(retry_after + 1)

        return script.actions.send_webhook(payload, false)
    end

    if status < 200 or status >= 300 then
        print("[biome hunt] webhook status " .. tostring(status) .. " " .. tostring(response.Body):sub(1, 120))
        return false
    end

    return true
end

-- // strictly passive: never invoke anything — just give events a moment to
-- // deliver stock on their own before the alert goes out
function script.actions.wait_for_stock(timeout)
    local deadline = os.clock() + (timeout or 5)

    while os.clock() < deadline and script.actions.script_active() do
        if script.state.merchant_name == nil or script.state.merchant_stock ~= nil then
            return
        end

        executor_env.__stella_biome_hunt_heartbeat = os.time()
        task.wait(0.5)
    end
end

function script.actions.notify_biome(biome, force)
    -- // one alert in flight at a time: the running call already includes
    -- // anything the merchant watcher detected while it waits for stock
    if script.state.notify_busy then
        return
    end

    local ping_tier = script.actions.is_ping_biome(biome)

    if not force then
        -- // dedupe: never post the same biome twice within 30 seconds
        if script.state.last_alert_biome == biome
            and os.clock() - script.state.last_alert_at < 30 then
            return
        end
    end

    script.state.notify_busy = true

    script.actions.wait_for_stock(10)

    local merchant = script.state.merchant_name or "None"
    local stock = script.state.merchant_stock or "unknown"
    local signature = biome .. "|" .. merchant .. "|" .. stock

    -- // a forced follow-up only goes out when something actually changed
    if force and signature == script.state.last_alert_signature then
        script.state.notify_busy = false
        return
    end

    local content = (ping_tier and "@everyone\n\n" or "")
        .. "**__Biome Hunt__**\n"
        .. "**Biome:** " .. biome .. "\n"
        .. "**Merchant:** " .. merchant .. "\n"

    if script.state.merchant_stock then
        content = content .. "**Stock:** " .. stock .. "\n"
    end

    content = content
        .. "**Players:** " .. script.actions.get_players_field() .. "\n"
        .. "**Hosted by:** " .. hosted_by .. "\n"
        .. "[Join Server](" .. script.actions.get_server_join_link(game.JobId) .. ")"

    local payload = {
        username = webhook_username,
        avatar_url = hosted_avatar,
        content = content,
        flags = 4,
    }

    if ping_tier then
        payload.allowed_mentions = { parse = { "everyone" } }
    end

    local delivered = script.actions.send_webhook(payload, true)

    script.state.last_alert_biome = biome
    script.state.last_alert_at = os.clock()

    if delivered then
        script.state.last_alert_signature = signature
    end

    script.state.notify_busy = false

    print("[biome hunt] biome " .. biome .. (delivered and " reported" or " report failed"))
end

function script.actions.fetch_server_candidates()
    local request_function = script.actions.get_request_function()

    if not request_function then
        print("[biome hunt] no http request function — using matchmaking fallback")
        return {}
    end

    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100",
        game.PlaceId)

    local ok, response = script.actions.request_with_timeout({ Url = url, Method = "GET" })

    if not ok then
        print("[biome hunt] server list request failed or timed out — using matchmaking fallback")
        return {}
    end

    if type(response) ~= "table" or (tonumber(response.StatusCode) or 0) ~= 200 then
        local status = type(response) == "table" and tostring(response.StatusCode) or "?"
        local body = type(response) == "table" and tostring(response.Body):sub(1, 120) or ""

        print("[biome hunt] server list status " .. status .. " " .. body)
        return {}
    end

    local ok_decode, data = pcall(function()
        return http_service:JSONDecode(response.Body)
    end)

    if not ok_decode or type(data) ~= "table" or type(data.data) ~= "table" then
        print("[biome hunt] server list response unparsable")
        return {}
    end

    -- // prefer quiet servers (2-5 players, listed lowest first); fall back to
    -- // any active server that is not full
    local quiet = {}
    local joinable = {}

    for _, server in ipairs(data.data) do
        if type(server) == "table" and server.id ~= game.JobId then
            local playing = tonumber(server.playing) or 0
            local max_players = tonumber(server.maxPlayers) or 12

            if playing >= 2 and playing < max_players then
                table.insert(joinable, server.id)

                if playing <= 5 then
                    table.insert(quiet, server.id)
                end
            end
        end
    end

    if #quiet > 0 then
        return quiet
    end

    return joinable
end

function script.actions.queue_rejoin()
    local queue_function = script.actions.get_queue_function()

    if not queue_function then
        print("[biome hunt] queue_on_teleport unavailable — hunting stops at this hop")
        return
    end

    local queued_source = 'if not game:IsLoaded() then game.Loaded:Wait() end '
        .. 'print("[biome hunt] rejoin loader fired") '
        .. 'pcall(function() getgenv().__stella_biome_hunt_heartbeat = 0 end) '
        .. 'local ok, err = pcall(function() '
        .. 'loadstring(game:HttpGet("' .. source_url .. '"))() end) '
        .. 'if not ok then print("[biome hunt] rejoin loader failed: " .. tostring(err)) end'

    local ok = pcall(queue_function, queued_source)

    print("[biome hunt] rejoin queue " .. (ok and "armed" or "failed"))
end

function script.actions.hop()
    script.actions.queue_rejoin()

    local candidates = script.actions.fetch_server_candidates()
    print("[biome hunt] hopping: " .. tostring(#candidates) .. " candidate servers")

    for attempt = 1, 3 do
        if #candidates == 0 then
            break
        end

        local target_job_id = candidates[math.random(1, #candidates)]
        local ok, err = pcall(function()
            teleport_service:TeleportToPlaceInstance(game.PlaceId, target_job_id, local_player)
        end)

        if ok then
            print("[biome hunt] teleport requested to " .. target_job_id)

            task.wait(12)
            return true
        end

        print("[biome hunt] teleport attempt " .. tostring(attempt) .. " failed: " .. tostring(err))
        task.wait(2)
    end

    local ok, err = pcall(function()
        teleport_service:Teleport(game.PlaceId, local_player)
    end)

    if ok then
        print("[biome hunt] fallback teleport requested")
        task.wait(12)
        return true
    end

    print("[biome hunt] fallback teleport failed: " .. tostring(err) .. " — retrying soon")
    task.wait(5)

    return false
end

function script.actions.wait_for_biome(timeout)
    local deadline = os.clock() + (timeout or biome_wait_seconds)

    while os.clock() < deadline and script.actions.script_active() do
        executor_env.__stella_biome_hunt_heartbeat = os.time()

        local biome = script.actions.get_current_biome()

        if biome ~= "Unknown" then
            print("[biome hunt] biome detected: " .. biome)
            return biome
        end

        task.wait(0.75)
    end

    print("[biome hunt] biome not detected — hopping anyway")
    return "Unknown"
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

    print("[biome hunt] starting (visit #" .. tostring(script.state.visit_number) .. ")")

    if not script.actions.looks_like_sols() then
        task.wait(8)

        if not script.actions.looks_like_sols() then
            print("[biome hunt] this does not look like Sol's RNG — stopping")
            return
        end
    end

    script.actions.start_replica_loader()
    script.actions.start_merchant_watcher()

    local biome = script.actions.wait_for_biome()
    local last_alerted = nil

    while script.actions.script_active() do
        executor_env.__stella_biome_hunt_heartbeat = os.time()

        local current = script.actions.get_current_biome()

        if current ~= "Unknown" then
            biome = current
        end

        if biome ~= "Unknown" and biome ~= last_alerted then
            script.actions.notify_biome(biome)
            last_alerted = biome
        end

        print("[biome hunt] cycle: biome=" .. tostring(biome)
            .. " merchant=" .. tostring(script.state.merchant_name or "none"))

        script.actions.settle_wait()

        if script.actions.script_active() then
            script.actions.hop()
        end
    end
end

-- // never run synchronously: run() never returns, and a loadstring call that
-- // blocks forever can crash high-level executors after a few rejoins
task.spawn(function()
    local ok, err = pcall(script.actions.run)

    if not ok then
        print("[biome hunt] crashed: " .. tostring(err))
    end
end)
