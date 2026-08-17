# biome hunt

Stella biome hunter for Sol's RNG. It server-hops, reads the biome in every server, and posts Discord webhook alerts with a **Join Server** button.

- posts every server's biome to your webhook with a join link
- pings `@everyone` for **Singularity / Dreamspace / Glitched / Cyberspace** (built in)
- separate **Merchant Spawned** alerts (Rin / Mari / Jester) with a join link
- stays in a server while a rare biome or merchant is active, then hops on
- re-queues itself after every hop and rejoin, so it keeps hunting until you stop it

## run it

```lua
getgenv().webhook = "https://discord.com/api/webhooks/YOUR/WEBHOOK"
loadstring(game:HttpGet("https://raw.githubusercontent.com/dissering/biome-hunt/main/script.luau"))()
```

`getgenv().webhook` is the only setting. It survives server hops (it lives in the executor environment, not in this repo), so alerts keep firing after every rejoin.

You can also just fill in the `local webhook = ""` line at the top of `script.luau` instead — `getgenv().webhook` wins over it when both are set.

## how it works

1. joins a server and reads the biome (server replica → `ServerInfo` attribute → UI label)
2. posts an embed with the biome, merchant status, and player count, plus a plain-text join link to that exact server
3. if the biome is rare or a merchant is around, waits there until it's over so the join button stays useful
4. hops to a random joinable server from the Roblox server list and repeats
5. every hop queues `queue_on_teleport` to re-run this script from the same URL

## stop it

Join any other game — the queued loader runs there and exits because it is not Sol's RNG. The hunt also stops by itself if this repo file is deleted.
