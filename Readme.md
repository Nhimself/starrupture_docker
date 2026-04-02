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
| `SESSION_NAME` | `My StarRupture Server` | Name shown in the server browser |
| `SAVE_GAME_INTERVAL` | `300` | Auto-save interval in seconds |
| `UPDATE_ON_START` | `true` | Run a SteamCMD update check on each container start |
| `RCON_PORT` | `27015` | RCON port (TCP) and Steam Query port (UDP). Leave blank to disable. |
| `RCON_PASSWORD` | — | RCON password. Leave blank to disable. |

## Password files

The server uses two password files for access control:

- `Password.json` — server join password
- `PlayerPassword.json` — in-game player password

Generate fresh files at [starrupture-utilities.com/passwords](https://starrupture-utilities.com/passwords/), replace the files in the repo root, then restart the container:

```bash
docker compose restart
```

The files included in this repo use the placeholder password `changeme`. Replace them before going live.

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

## Tools

[starrupture-utilities.com](https://starrupture-utilities.com/) provides a web-based toolset for server management and debugging, including log review and save game inspection and modification.
