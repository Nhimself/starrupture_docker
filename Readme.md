# StarRupture Dedicated Server (Docker)

Runs the [StarRupture](https://store.steampowered.com/app/3809400/StarRupture/) dedicated server on Linux via Docker. The server binary is Windows-only, so it runs through [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) inside the container. The [StarRupture ModLoader](https://github.com/AlienXAXS/StarRupture-ModLoader) is installed automatically on first start.

## Requirements

- Docker and Docker Compose
- ~10 GB disk space (game files + Proton)
- 8–16 GB RAM

## Quick start

```bash
cp .env.example .env
# Edit .env — at minimum set MULTIHOME to your server's public IP
docker compose build
docker compose up -d
docker compose logs -f
```

The first start downloads the game files and initialises the Proton prefix. This takes several minutes.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `MULTIHOME` | — | **Required.** Your server's public IP. Without this, clients see Docker's internal IP and cannot connect. |
| `SERVER_PORT` | `7777` | Game port (UDP) |
| `UPDATE_ON_START` | `true` | Run a SteamCMD update check on each container start |
| `RCON_PORT` | `27015` | RCON port (TCP) and Steam Query port (UDP). Leave blank to disable. |
| `RCON_PASSWORD` | — | RCON password. Leave blank to disable. |
| `ADMIN_PASSWORD` | — | Server join password. Leave blank to disable. |
| `PLAYER_PASSWORD` | — | In-game player password. Leave blank to disable. |

## Password files

Set `ADMIN_PASSWORD` and/or `PLAYER_PASSWORD` in your `.env`. On each container start the entrypoint calls [starrupture-utilities.com/passwords](https://starrupture-utilities.com/passwords/) to encrypt the values and writes `Password.json` / `PlayerPassword.json` into the server directory automatically. Leave either variable blank to remove that password file.

## Save files

Save games are bind-mounted to `./saves/` so they survive `docker compose down -v` or accidental volume wipes. Back this folder up externally.

## Ports

Open these on your firewall/router:

| Port | Protocol | Purpose |
|---|---|---|
| `SERVER_PORT` (7777) | UDP | Game traffic |

> **UDP only.** Do not open TCP on this port. The server has a known remote control vulnerability — see the [security announcement](https://wiki.starrupture-utilities.com/en/dedicated-server/Vulnerability-Announcement). The ModLoader patches it, but opening TCP still exposes the attack surface.

## Logs

```bash
docker compose logs -f
```

The server log (`StarRupture/Saved/Logs/StarRupture.log`) is also streamed to container stdout.

## Mod updates

`update-mods.sh` downloads the latest releases of the ModLoader and plugins, restarts the server, and verifies it loaded the correct map. If the server falls back to the `DedicatedServer` map it sends a Discord alert.

**What it updates:**
- [StarRupture-ModLoader](https://github.com/AlienXAXS/StarRupture-ModLoader) → `modloader/dwmapi.dll`
- [StarRupture-Plugin-KeepTicking](https://github.com/AlienXAXS/StarRupture-Plugin-KeepTicking) → `modloader/Plugins/`
- [StarRupture-Plugin-ServerUtility](https://github.com/AlienXAXS/StarRupture-Plugin-ServerUtility) → `modloader/Plugins/`

### Dependencies

```bash
apt install curl jq unzip
```

### Configuration

Add these to your `.env`:

| Variable | Required | Description |
|---|---|---|
| `DISCORD_WEBHOOK_URL` | Optional | Webhook URL for map-load failure alerts |
| `GITHUB_TOKEN` | Optional | GitHub PAT — avoids the 60 req/hr unauthenticated API rate limit |
| `MAP_LOAD_TIMEOUT` | Optional | Seconds to wait for map load confirmation (default: `600`) |

### Run manually

```bash
chmod +x update-mods.sh
./update-mods.sh
```

### Schedule with systemd

```bash
sudo cp systemd/starrupture-mod-update.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now starrupture-mod-update.timer
```

The timer fires every **Wednesday at 04:00** local time. Edit `OnCalendar=` in `systemd/starrupture-mod-update.timer` to change the schedule, then run `sudo systemctl daemon-reload`.

Check status and logs:

```bash
systemctl status starrupture-mod-update.timer
journalctl -u starrupture-mod-update.service -f
```

Run immediately without waiting for the timer:

```bash
sudo systemctl start starrupture-mod-update.service
```

## Tools

[starrupture-utilities.com](https://starrupture-utilities.com/) provides a web-based toolset for server management and debugging, including log review and save game inspection and modification.
