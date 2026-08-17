# biome hunt

Stella biome hunter for Sol's RNG. It server-hops, reads the biome in every server, and posts Discord webhook alerts with a **Join Server** button.

- posts every server's biome to your webhook with a join button
- pings `@everyone` for **Singularity / Dreamspace / Glitched**
- separate **Merchant Spawned** alerts (Rin / Mari / Jester) with a join button
- stays in a server while a rare biome or merchant is active, then hops on
- re-queues itself after every hop and rejoin, so it keeps hunting until you stop it

## run it

```lua
getgenv().webhook = "https://discord.com/api/webhooks/YOUR/WEBHOOK"
loadstring(game:HttpGet("https://raw.githubusercontent.com/dissering/biome-hunt/main/biome-hunt.lua"))()
```

`getgenv().webhook` is the only required setting. It survives server hops (it lives in the executor environment, not in this repo), so alerts keep firing after every rejoin.

## customize

Set `getgenv().biome_hunt` to a table before the loadstring — any key from the config table in `biome-hunt.lua`:

```lua
getgenv().biome_hunt = {
    webhook_url = "https://discord.com/api/webhooks/YOUR/WEBHOOK",
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

loadstring(game:HttpGet("https://raw.githubusercontent.com/dissering/biome-hunt/main/biome-hunt.lua"))()
```

`getgenv().webhook` wins over `webhook_url` in the table.

| key | what it does |
| --- | --- |
| `source_url` | where the script re-loads itself from after a hop |
| `webhook_url` | discord webhook url (or just use `getgenv().webhook`) |
| `webhook_username` | username shown on the webhook messages |
| `logo_url` | webhook avatar + embed thumbnail image |
| `ping_everyone_biomes` | biomes that ping `@everyone` |
| `report_all_servers` | `true` = post every server's biome, `false` = only notable biomes and merchants |
| `stay_on_rare` | stay in the server while a notable biome is active |
| `stay_on_merchant` | stay in the server while a merchant is active |
| `merchant_mention_user_id` | optional user id to mention when a merchant spawns |
| `min_server_players` | skip hop targets with fewer players than this |
| `settle_delay_range` | random wait in seconds between the report and the hop |
| `stay_cap_seconds` | max seconds to stay in one server for a rare biome or merchant |
| `biome_wait_seconds` | max seconds to wait for biome detection after joining |
| `request_timeout_seconds` | abandon http requests after this many seconds |

## how it works

1. joins a server and reads the biome (server replica → `ServerInfo` attribute → UI label)
2. posts an embed with the biome, merchant status, and player count, plus a join button linking that exact server
3. if the biome is rare or a merchant is around, waits there so the join button stays useful
4. hops to a random joinable server from the Roblox server list and repeats
5. every hop queues `queue_on_teleport` to re-run this script from the same URL

## stop it

Join any other game — the queued loader runs there and exits because it is not Sol's RNG. The hunt also stops by itself if this repo file is deleted.
