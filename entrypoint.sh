#!/bin/bash
set -e

# --- Configuration from environment ---
SERVER_PORT="${SERVER_PORT:-7777}"
START_NEW_GAME="${START_NEW_GAME:-true}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"

STEAMCMD="/home/steam/steamcmd/steamcmd.sh"
SERVER_DIR="/home/steam/serverfiles"
PROTON_DIR="/home/steam/proton"
SERVER_EXE="StarRupture/Binaries/Win64/StarRuptureServerEOS-Win64-Shipping.exe"
DS_SETTINGS="$SERVER_DIR/StarRupture/Binaries/Win64/DSSettings.txt"

# Proton environment
export STEAM_COMPAT_DATA_PATH="${SERVER_DIR}/compatdata"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="/home/steam/steamcmd"

# --- Signal handling for graceful shutdown ---
SERVER_PID=""
LOG_PID=""
SERVER_LOG="$SERVER_DIR/StarRupture/Saved/Logs/StarRupture.log"

shutdown() {
    echo "[entrypoint] Caught shutdown signal, stopping server..."
    if [ -n "$LOG_PID" ]; then
        kill "$LOG_PID" 2>/dev/null || true
    fi
    if [ -n "$SERVER_PID" ]; then
        kill -SIGINT "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    echo "[entrypoint] Server stopped."
    exit 0
}

trap shutdown SIGTERM SIGINT

# --- Install / Update server ---
if [ "$UPDATE_ON_START" = "true" ]; then
    echo "[entrypoint] Updating StarRupture Dedicated Server (App 3809400)..."
    MAX_RETRIES=3
    RETRY=0
    until [ "$RETRY" -ge "$MAX_RETRIES" ]; do
        "$STEAMCMD" \
            +@sSteamCmdForcePlatformType windows \
            +force_install_dir "$SERVER_DIR" \
            +login anonymous \
            +app_update 3809400 validate \
            +quit && break
        RETRY=$((RETRY + 1))
        echo "[entrypoint] SteamCMD failed (attempt $RETRY/$MAX_RETRIES), retrying in 5s..."
        sleep 5
    done
    if [ "$RETRY" -ge "$MAX_RETRIES" ]; then
        echo "[entrypoint] ERROR: SteamCMD failed after $MAX_RETRIES attempts."
        exit 1
    fi
    echo "[entrypoint] Update complete."
fi

# --- Initialize Proton prefix ---
mkdir -p "$STEAM_COMPAT_DATA_PATH"

if [ ! -d "$STEAM_COMPAT_DATA_PATH/pfx" ]; then
    echo "[entrypoint] Initializing Proton prefix (first run, this may take a minute)..."
    cd "$SERVER_DIR"
    "$PROTON_DIR/proton" run cmd /c "echo Prefix initialized" || true
    echo "[entrypoint] Proton prefix initialized."
fi

# --- Verify server binary exists ---
if [ ! -f "$SERVER_DIR/$SERVER_EXE" ]; then
    echo "[entrypoint] ERROR: Server binary not found at $SERVER_DIR/$SERVER_EXE"
    echo "[entrypoint] The server may not have downloaded correctly. Check SteamCMD output above."
    exit 1
fi

# --- Create DSSettings.txt if it doesn't exist ---
if [ ! -f "$DS_SETTINGS" ]; then
    echo "[entrypoint] Creating default DSSettings.txt (StartNewGame=$START_NEW_GAME)..."
    cat > "$DS_SETTINGS" <<EOF
{
  "SessionName": "MySaveGame",
  "SaveGameInterval": "300",
  "StartNewGame": "$START_NEW_GAME",
  "LoadSavedGame": "false",
  "SaveGameName": "AutoSave0.sav"
}
EOF
else
    echo "[entrypoint] DSSettings.txt already exists, using existing config."
fi

# --- Build server launch arguments (match Windows: just -Log -Port) ---
LAUNCH_ARGS=(
    -Log
    -Port="$SERVER_PORT"
)

# Append any extra arguments passed to the container
if [ $# -gt 0 ]; then
    LAUNCH_ARGS+=("$@")
fi

# --- Launch server ---
echo "[entrypoint] Starting StarRupture Dedicated Server..."
echo "[entrypoint]   Port: $SERVER_PORT"
echo "[entrypoint]   Args: ${LAUNCH_ARGS[*]}"
echo "[entrypoint]   DSSettings: $DS_SETTINGS"

cd "$SERVER_DIR"

# Use xvfb-run for headless display, then launch via Proton
xvfb-run -a "$PROTON_DIR/proton" run "./$SERVER_EXE" "${LAUNCH_ARGS[@]}" &
SERVER_PID=$!

echo "[entrypoint] Server launched with PID $SERVER_PID, waiting for log output..."

# Wait for the log file to appear, then tail it to stdout
WAIT_COUNT=0
while [ ! -f "$SERVER_LOG" ] && [ "$WAIT_COUNT" -lt 60 ]; do
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ -f "$SERVER_LOG" ]; then
    echo "[entrypoint] Streaming server log to stdout..."
    tail -n 0 -f "$SERVER_LOG" &
    LOG_PID=$!
else
    echo "[entrypoint] WARNING: Server log file not found after 60s, cannot stream logs."
fi

# Wait for server process (allows signal handling)
wait "$SERVER_PID"
EXIT_CODE=$?
echo "[entrypoint] Server process exited with code $EXIT_CODE"
