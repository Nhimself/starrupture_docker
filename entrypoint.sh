#!/bin/bash
set -e

# --- Configuration from environment ---
SERVER_PORT="${SERVER_PORT:-7777}"
MULTIHOME="${MULTIHOME:-}"
SESSION_NAME="${SESSION_NAME:-My StarRupture Server}"
SAVE_GAME_INTERVAL="${SAVE_GAME_INTERVAL:-300}"
RCON_PORT="${RCON_PORT:-}"
RCON_PASSWORD="${RCON_PASSWORD:-}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
INSTALL_MODLOADER="${INSTALL_MODLOADER:-true}"

STEAMCMD="/home/steam/steamcmd/steamcmd.sh"
SERVER_DIR="/home/steam/serverfiles"
PROTON_DIR="/home/steam/proton"
SERVER_EXE="StarRupture/Binaries/Win64/StarRuptureServerEOS-Win64-Shipping.exe"

# Proton environment
export STEAM_COMPAT_DATA_PATH="${SERVER_DIR}/compatdata"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="/home/steam/steamcmd"

# --- Signal handling for graceful shutdown ---
SERVER_PID=""
BOOTSTRAP_PID=""
LOG_PID=""
SERVER_LOG="$SERVER_DIR/StarRupture/Saved/Logs/StarRupture.log"

shutdown() {
    echo "[entrypoint] Caught shutdown signal, stopping server..."
    if [ -n "$LOG_PID" ]; then
        kill "$LOG_PID" 2>/dev/null || true
    fi
    # BOOTSTRAP_PID is set during first-run bootstrap; SERVER_PID during normal run
    for PID in "$BOOTSTRAP_PID" "$SERVER_PID"; do
        if [ -n "$PID" ]; then
            kill -SIGINT "$PID" 2>/dev/null || true
            wait "$PID" 2>/dev/null || true
        fi
    done
    echo "[entrypoint] Server stopped."
    exit 0
}

trap shutdown SIGTERM SIGINT

# --- Install / Update server ---
# Always run SteamCMD on first install (binary missing), regardless of UPDATE_ON_START.
# UPDATE_ON_START=false only skips the update check when the server is already installed.
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

# --- Initialize Proton prefix ---
mkdir -p "$STEAM_COMPAT_DATA_PATH"

if [ ! -d "$STEAM_COMPAT_DATA_PATH/pfx" ]; then
    echo "[entrypoint] Initializing Proton prefix (first run, this may take a minute)..."
    cd "$SERVER_DIR"
    xvfb-run -a "$PROTON_DIR/proton" run cmd /c "echo Prefix initialized" || true
    if [ ! -d "$STEAM_COMPAT_DATA_PATH/pfx" ]; then
        echo "[entrypoint] ERROR: Proton prefix failed to initialize. Check Proton/Wine setup."
        exit 1
    fi
    echo "[entrypoint] Proton prefix initialized."
fi

# --- Verify server binary exists ---
# Catches edge cases where SteamCMD succeeded but the binary is still missing.
if [ ! -f "$SERVER_DIR/$SERVER_EXE" ]; then
    echo "[entrypoint] ERROR: Server binary not found at $SERVER_DIR/$SERVER_EXE"
    echo "[entrypoint] SteamCMD reported success but the binary is missing — check the SteamCMD output above."
    exit 1
fi


SERVER_EXE_DIR="$SERVER_DIR/StarRupture/Binaries/Win64"
PLUGINS_CONFIG_DIR="$SERVER_EXE_DIR/Plugins/config"

if [ "$INSTALL_MODLOADER" = "true" ]; then
    # Required for ModLoader DLL proxy — must be set before any server launch
    export WINEDLLOVERRIDES="dwmapi=n,b"

    # --- Bootstrap: first launch to let the ModLoader generate plugin config files ---
    # Plugins are disabled by default on first run. We start the server briefly,
    # wait for the INI files to appear, then kill it and enable all plugins before
    # the real launch below.
    if [ ! -f "$PLUGINS_CONFIG_DIR/KeepTicking.ini" ]; then
        echo "[entrypoint] First run detected — bootstrapping ModLoader plugin configs..."
        cd "$SERVER_DIR"
        xvfb-run -a "$PROTON_DIR/proton" run "./$SERVER_EXE" -Log &
        BOOTSTRAP_PID=$!

        echo "[entrypoint] Waiting for plugin config files to be generated (up to 120s)..."
        WAIT=0
        until [ -f "$PLUGINS_CONFIG_DIR/KeepTicking.ini" ] || [ "$WAIT" -ge 120 ]; do
            sleep 2
            WAIT=$((WAIT + 2))
        done

        kill "$BOOTSTRAP_PID" 2>/dev/null || true
        wait "$BOOTSTRAP_PID" 2>/dev/null || true
        BOOTSTRAP_PID=""

        if [ ! -f "$PLUGINS_CONFIG_DIR/KeepTicking.ini" ]; then
            echo "[entrypoint] WARNING: Bootstrap timed out — plugin configs were not generated. Plugins may be inactive."
        else
            echo "[entrypoint] Bootstrap complete."
        fi
    fi

    # --- Enable all server plugins ---
    for PLUGIN in KeepTicking RailJunctionFixer ServerUtility; do
        INI_FILE="$PLUGINS_CONFIG_DIR/$PLUGIN.ini"
        if [ -f "$INI_FILE" ]; then
            sed -i 's/^Enabled=0/Enabled=1/' "$INI_FILE"
            echo "[entrypoint] Plugin enabled: $PLUGIN"
        else
            echo "[entrypoint] WARNING: $PLUGIN config not found — plugin will not be active this run."
        fi
    done
else
    echo "[entrypoint] INSTALL_MODLOADER=false — skipping ModLoader install."
fi

# --- Build server launch arguments ---
LAUNCH_ARGS=(
    -Log
    -Port="$SERVER_PORT"
    -RCWebControlDisable
    -RCWebInterfaceDisable
    -SessionName="$SESSION_NAME"
    -SaveGameInterval="$SAVE_GAME_INTERVAL"
)

# Add MULTIHOME if set
if [ -n "$MULTIHOME" ]; then
    LAUNCH_ARGS+=(-MULTIHOME="$MULTIHOME")
fi

# Add RCON if configured
if [ -n "$RCON_PORT" ]; then
    LAUNCH_ARGS+=(-RconPort="$RCON_PORT")
fi
if [ -n "$RCON_PASSWORD" ]; then
    LAUNCH_ARGS+=(-RconPassword="$RCON_PASSWORD")
fi

# Append any extra arguments passed to the container
if [ $# -gt 0 ]; then
    LAUNCH_ARGS+=("$@")
fi

# --- Launch server ---
echo "[entrypoint] Starting StarRupture Dedicated Server..."
echo "[entrypoint]   Port:      $SERVER_PORT"
echo "[entrypoint]   Multihome: ${MULTIHOME:-<not set>}"
echo "[entrypoint]   Session:   $SESSION_NAME"
echo "[entrypoint]   RCON port: ${RCON_PORT:-<disabled>}"

cd "$SERVER_DIR"

# Use xvfb-run for headless display, then launch via Proton
xvfb-run -a "$PROTON_DIR/proton" run "./$SERVER_EXE" "${LAUNCH_ARGS[@]}" &
SERVER_PID=$!

echo "[entrypoint] Server launched with PID $SERVER_PID, waiting for log output..."

# Wait for the log file to appear, then tail it to stdout
WAIT_COUNT=0
while [ ! -f "$SERVER_LOG" ] && [ "$WAIT_COUNT" -lt 60 ] && kill -0 "$SERVER_PID" 2>/dev/null; do
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
# Use || to prevent set -e from exiting before we can capture and log the exit code
wait "$SERVER_PID" && EXIT_CODE=0 || EXIT_CODE=$?
echo "[entrypoint] Server process exited with code $EXIT_CODE"
