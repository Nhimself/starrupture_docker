#!/bin/bash
set -e

# --- Configuration from environment ---
SERVER_PORT="${SERVER_PORT:-7777}"
MULTIHOME="${MULTIHOME:-}"
SESSION_NAME="${SESSION_NAME:-sr.mcros.dk}"
SAVE_GAME_INTERVAL="${SAVE_GAME_INTERVAL:-300}"
RCON_PORT="${RCON_PORT:-}"
RCON_PASSWORD="${RCON_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
PLAYER_PASSWORD="${PLAYER_PASSWORD:-}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"

STEAMCMD="/home/steam/steamcmd/steamcmd.sh"
SERVER_DIR="/home/steam/serverfiles"
PROTON_DIR="/home/steam/proton"
SERVER_EXE="StarRupture/Binaries/Win64/StarRuptureServerEOS-Win64-Shipping.exe"
SERVER_EXE_DIR="$SERVER_DIR/StarRupture/Binaries/Win64"

# Proton environment
export STEAM_COMPAT_DATA_PATH="${SERVER_DIR}/compatdata/3809400"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="/home/steam/steamcmd"

# Address the NNERuntimeORT (DirectML) Crash
export VK_ICD_FILENAMES=/dev/null
export MESA_LOADER_DRIVER_OVERRIDE=none

# Force Proton to report NO Vulkan/GL devices
export VK_ICD_FILENAMES=/dev/null
export MESA_LOADER_DRIVER_OVERRIDE=none
export LIBGL_ALWAYS_SOFTWARE=1

# Disable the specific DLLs Unreal uses to probe for AI/NNE hardware
export WINEDLLOVERRIDES="dxcore=d;directml=d;d3d12=d;d3d11=d;dwmapi=n,b"

# --- Signal handling for graceful shutdown ---
SERVER_PID=""
LOG_PID=""
SERVER_LOG="$SERVER_DIR/StarRupture/Saved/Logs/StarRupture.log"

shutdown() {
    echo "[entrypoint] Caught shutdown signal, stopping server..."
    if [ -n "$LOG_PID" ]; then
        kill "$LOG_PID" 2>/dev/null || true
    fi
    for PID in "$SERVER_PID"; do
        if [ -n "$PID" ]; then
            kill -SIGINT "$PID" 2>/dev/null || true
            wait "$PID" 2>/dev/null || true
        fi
    done
    echo "[entrypoint] Server stopped."
    exit 0
}

trap shutdown SIGTERM SIGINT

# --- Pre-create game directory tree ---
# Ensures bind-mounted files/dirs in docker-compose land correctly regardless
# of whether the game has been installed yet.
mkdir -p "$SERVER_EXE_DIR"
mkdir -p "$SERVER_EXE_DIR/Plugins/config"
mkdir -p "$SERVER_DIR/StarRupture/Saved/Logs"
mkdir -p "$SERVER_DIR/StarRupture/Saved/SaveGames"

# --- Install / Update server ---
NEEDS_INSTALL=false
if [ ! -f "$SERVER_DIR/$SERVER_EXE" ]; then
    echo "[entrypoint] Server binary not found — running initial install..."
    NEEDS_INSTALL=true
fi

if [ "$UPDATE_ON_START" = "true" ] || [ "$NEEDS_INSTALL" = "true" ]; then
    echo "[entrypoint] Updating StarRupture Dedicated Server (App 3809400)..."
    "$STEAMCMD" \
        +@ShutdownOnFailedCommand 1 \
        +@NoPromptForPassword 1 \
        +@sSteamCmdForcePlatformBitness 64 \
        +@sSteamCmdForcePlatformType windows \
        +force_install_dir "$SERVER_DIR" \
        +login anonymous \
        +app_update 3809400 \
        +quit
    echo "[entrypoint] Update complete."
fi

# --- Verify server binary ---
if [ ! -f "$SERVER_DIR/$SERVER_EXE" ]; then
    echo "[entrypoint] ERROR: Server binary not found at $SERVER_DIR/$SERVER_EXE"
    exit 1
fi

# --- Initialize Proton prefix ---
mkdir -p "$STEAM_COMPAT_DATA_PATH"

if [ ! -d "$STEAM_COMPAT_DATA_PATH/pfx" ]; then
    echo "[entrypoint] Initializing Proton prefix (first run, this may take a minute)..."
    cd "$SERVER_DIR"
    xvfb-run -a "$PROTON_DIR/proton" run cmd /c "echo Prefix initialized" || true
    if [ ! -d "$STEAM_COMPAT_DATA_PATH/pfx" ]; then
        echo "[entrypoint] ERROR: Proton prefix failed to initialize."
        exit 1
    fi
    echo "[entrypoint] Proton prefix initialized."
fi

# --- Generate password files ---
generate_password_files() {
    if [ -z "$ADMIN_PASSWORD" ] && [ -f "$SERVER_DIR/Password.json" ]; then
        rm -f "$SERVER_DIR/Password.json"
        echo "[entrypoint] Removed admin password file (ADMIN_PASSWORD not set)."
    fi
    if [ -z "$PLAYER_PASSWORD" ] && [ -f "$SERVER_DIR/PlayerPassword.json" ]; then
        rm -f "$SERVER_DIR/PlayerPassword.json"
        echo "[entrypoint] Removed player password file (PLAYER_PASSWORD not set)."
    fi

    [ -z "$ADMIN_PASSWORD" ] && [ -z "$PLAYER_PASSWORD" ] && return

    echo "[entrypoint] Generating encrypted password files..."
    local response
    response=$(curl -sf -X POST https://starrupture-utilities.com/passwords/ \
        -d "adminpassword=${ADMIN_PASSWORD}" \
        -d "playerpassword=${PLAYER_PASSWORD}") || {
        echo "[entrypoint] WARNING: Failed to reach starrupture-utilities.com — password files not updated."
        return
    }

    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "{\"password\":\"$(echo "$response" | jq -r '.adminpassword')\"}" \
            > "$SERVER_DIR/Password.json"
        echo "[entrypoint] Admin password configured."
    fi
    if [ -n "$PLAYER_PASSWORD" ]; then
        echo "{\"password\":\"$(echo "$response" | jq -r '.playerpassword')\"}" \
            > "$SERVER_DIR/PlayerPassword.json"
        echo "[entrypoint] Player password configured."
    fi
}

generate_password_files


# --- Build server launch arguments ---
LAUNCH_ARGS=(
    -Log
    -Port="$SERVER_PORT"
    -RCWebControlDisable
    -RCWebInterfaceDisable
)

# If the modloader is present, ServerUtility reads session/RCON config from CLI args.
# Without it, session config comes from DSSettings.txt at the serverfiles root.
if [ -f "$SERVER_EXE_DIR/dwmapi.dll" ]; then
    echo "[entrypoint] Modloader detected — adding session and RCON args."
    LAUNCH_ARGS+=(
        -SessionName="$SESSION_NAME"
        -SaveGameInterval="$SAVE_GAME_INTERVAL"
    )
    if [ -n "$RCON_PORT" ]; then
        LAUNCH_ARGS+=(-RconPort="$RCON_PORT")
    fi
    if [ -n "$RCON_PASSWORD" ]; then
        LAUNCH_ARGS+=(-RconPassword="$RCON_PASSWORD")
    fi
fi

if [ -n "$MULTIHOME" ]; then
    LAUNCH_ARGS+=(-MULTIHOME="$MULTIHOME")
fi
if [ $# -gt 0 ]; then
    LAUNCH_ARGS+=("$@")
fi

# --- Launch server ---
echo "[entrypoint] Starting StarRupture Dedicated Server..."
echo "[entrypoint]   Port:        $SERVER_PORT"
echo "[entrypoint]   Multihome:   ${MULTIHOME:-<not set>}"
echo "[entrypoint]   RCON port:   ${RCON_PORT:-<disabled>}"
if [ -f "$SERVER_EXE_DIR/dwmapi.dll" ]; then
    echo "[entrypoint]   Modloader:   enabled"
else
    echo "[entrypoint]   Modloader:   disabled (DSSettings.txt mode)"
fi
echo "[entrypoint]   Launch args: ${LAUNCH_ARGS[@]}"

cd "$SERVER_DIR"

echo "3809400" > "$SERVER_EXE_DIR/steam_appid.txt"

xvfb-run -a "$PROTON_DIR/proton" waitforexitandrun "./$SERVER_EXE" "${LAUNCH_ARGS[@]}" & 
sleep 5
SERVER_PID=$!

echo "[entrypoint] Server launched with PID $SERVER_PID, waiting for log output..."

# Wait for a fresh log file (game rotates the log on each start)
LAUNCH_TIME=$(date +%s)
WAIT_COUNT=0
while [ "$WAIT_COUNT" -lt 60 ] && kill -0 "$SERVER_PID" 2>/dev/null; do
    if [ -f "$SERVER_LOG" ] && [ "$(date -r "$SERVER_LOG" +%s 2>/dev/null || echo 0)" -ge "$LAUNCH_TIME" ]; then
        break
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ -f "$SERVER_LOG" ]; then
    echo "[entrypoint] Streaming server log to stdout..."
    tail -n 0 -F "$SERVER_LOG" &
    LOG_PID=$!
else
    echo "[entrypoint] WARNING: Server log file not found after 60s."
fi

wait "$SERVER_PID" && EXIT_CODE=0 || EXIT_CODE=$?
echo "[entrypoint] Server process exited with code $EXIT_CODE"
