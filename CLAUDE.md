# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker image for running the StarRupture Dedicated Server (Steam App 3809400) on Linux. The server binary is Windows-only, so it runs via GE-Proton inside the container.

## Architecture

- **Base image**: `cm2network/steamcmd:root` (Debian bullseye-slim with SteamCMD at `/home/steam/steamcmd`)
- **Proton**: GE-Proton downloaded from GitHub releases, installed to `/home/steam/proton`
- **Game files**: Stored in a Docker volume at `/home/steam/serverfiles` (persisted across restarts)
- **Entrypoint**: `entrypoint.sh` handles SteamCMD update, Proton prefix init, and server launch
- **Headless**: Uses `xvfb-run` for virtual framebuffer (no GPU/display needed)

## Build & Run

```bash
# Copy and edit environment
cp .env.example .env

# Build and start
docker compose build
docker compose up -d

# View logs
docker compose logs -f

# Stop
docker compose down
```

## Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_NAME` | `My StarRupture Server` | Server display name |
| `SERVER_PORT` | `7777` | Game port (UDP) |
| `QUERY_PORT` | `27015` | Query port (UDP) |
| `MULTIHOME` | `0.0.0.0` | Bind address |
| `UPDATE_ON_START` | `true` | Run SteamCMD update on container start |

## Important Paths Inside Container

- SteamCMD: `/home/steam/steamcmd/steamcmd.sh`
- GE-Proton: `/home/steam/proton/proton`
- Server binary: `/home/steam/serverfiles/StarRupture/Binaries/Win64/StarRuptureServerEOS-Win64-Shipping.exe`
- Proton prefix: `/home/steam/serverfiles/compatdata/`

## Known Considerations

- First start is slow (downloads ~several GB of game files + initializes Proton prefix)
- The server is reported to use high RAM; ensure the host has sufficient memory
- The Dockerfile uses the `:root` tag to install packages, then switches to `steam` user
- GE-Proton version is pinned via `GE_PROTON_VERSION` build arg in the Dockerfile
