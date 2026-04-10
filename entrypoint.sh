#!/bin/bash
set -e

# --- Configuration from environment ---
SERVER_PORT="${SERVER_PORT:-7777}"
MULTIHOME="${MULTIHOME:-}"
RCON_PORT="${RCON_PORT:-}"
RCON_PASSWORD="${RCON_PASSWORD:-}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
INSTALL_MODLOADER="${INSTALL_MODLOADER:-true}"

STEAMCMD="/home/steam/steamcmd/steamcmd.sh"
SERVER_DIR="/home/steam/serverfiles"
PROTON_DIR="/home/steam/proton"
SERVER_EXE="StarRuptureServerEOS.exe"
SERVER_EXE_DIR="$SERVER_DIR/StarRupture/Binaries/Win64"
SHIPPING_EXE_NAME="StarRuptureServerEOS-Win64-Shipping.exe"

# Proton environment
export STEAM_COMPAT_DATA_PATH="${SERVER_DIR}/compatdata/3809400"
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
    for PID in "$BOOTSTRAP_PID" "$SERVER_PID"; do
        if [ -n "$PID" ]; then
            kill -SIGINT "$PID" 2>/dev/null || true
            # Give the process up to 25s to shut down gracefully before forcing
            for _ in $(seq 1 25); do
                kill -0 "$PID" 2>/dev/null || break
                sleep 1
            done
            kill -9 "$PID" 2>/dev/null || true
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

# --- steam_appid.txt ---
# Required by the BootstrapPackagedGame launcher (StarRuptureServerEOS.exe) so Wine's
# steam.exe stub can identify the app without a real Steam client session.
echo "3809400" > "$SERVER_DIR/steam_appid.txt"

# --- DSSettings.txt ---
# Controls session name, save game loading, and auto-save interval.
# CLI args for these no longer work after the major game update.
# Auto-generated with defaults on first run; leave untouched on subsequent runs
# so the server always loads cleanly without requiring a flag-switching dance.
# To use your own file: uncomment the DSSettings.txt bind mount in docker-compose.yml.
DS_SETTINGS="$SERVER_EXE_DIR/DSSettings.txt"
DEFAULT_SESSION="MySaveGame"

if [ ! -f "$DS_SETTINGS" ]; then
    echo "[entrypoint] No DSSettings.txt found — creating default (session: $DEFAULT_SESSION)..."
    cat > "$DS_SETTINGS" << EOF
{
  "SessionName": "$DEFAULT_SESSION",
  "SaveGameInterval": "300",
  "StartNewGame": "false",
  "LoadSavedGame": "true",
  "SaveGameName": "AutoSave0.sav"
}
EOF
    echo "[entrypoint] DSSettings.txt created."
else
    echo "[entrypoint] DSSettings.txt present — skipping generation."
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

# --- Verify server binaries exist ---
if [ ! -f "$SERVER_DIR/$SERVER_EXE" ]; then
    echo "[entrypoint] ERROR: Launcher not found at $SERVER_DIR/$SERVER_EXE"
    exit 1
fi
if [ ! -f "$SERVER_DIR/StarRupture/Binaries/Win64/$SHIPPING_EXE_NAME" ]; then
    echo "[entrypoint] ERROR: Shipping binary not found at $SERVER_DIR/StarRupture/Binaries/Win64/$SHIPPING_EXE_NAME"
    exit 1
fi

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
        xvfb-run -a "$PROTON_DIR/proton" waitforexitandrun "./$SERVER_EXE" -Log &
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
echo "[entrypoint]   RCON port: ${RCON_PORT:-<disabled>}"

cd "$SERVER_DIR"

# Launch via the official launcher. StarRuptureServerEOS.exe is a bootstrap launcher —
# it spawns StarRuptureServerEOS-Win64-Shipping.exe and then exits. So we must not
# track the launcher PID; instead we wait for the Shipping process to appear and
# monitor that directly.
LAUNCH_TIME=$(date +%s)
xvfb-run -a "$PROTON_DIR/proton" waitforexitandrun "./$SERVER_EXE" "${LAUNCH_ARGS[@]}"
echo "[entrypoint] Launcher exited — waiting for Shipping process to appear (up to 60s)..."

SHIPPING_PID=""
WAIT_COUNT=0
while [ "$WAIT_COUNT" -lt 60 ]; do
    SHIPPING_PID=$(pgrep -f "$SHIPPING_EXE_NAME" | head -1)
    [ -n "$SHIPPING_PID" ] && break
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ -z "$SHIPPING_PID" ]; then
    echo "[entrypoint] ERROR: Shipping process never appeared after 60s — launcher may have failed."
    exit 1
fi
echo "[entrypoint] Shipping process running with PID $SHIPPING_PID"

# Wait for a fresh log file (the game rotates on each start)
WAIT_COUNT=0
while [ "$WAIT_COUNT" -lt 60 ]; do
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
    echo "[entrypoint] WARNING: Server log file not found after 60s, cannot stream logs."
fi

# Wait on the Shipping process directly
SERVER_PID="$SHIPPING_PID"
while kill -0 "$SERVER_PID" 2>/dev/null; do
    sleep 5
done
echo "[entrypoint] Server process exited."
