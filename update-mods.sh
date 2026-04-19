#!/bin/bash
# Update StarRupture ModLoader and plugins from their latest GitHub releases,
# then verify the server loads ChimeraMain (not the fallback DedicatedServer map).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODLOADER_DIR="$SCRIPT_DIR/modloader"
PLUGINS_DIR="$MODLOADER_DIR/Plugins"
VERSIONS_FILE="$MODLOADER_DIR/.versions"
LOG_FILE="$SCRIPT_DIR/Saved/Logs/StarRupture.log"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"

# Load DISCORD_WEBHOOK_URL from .env if not set in environment
if [ -z "${DISCORD_WEBHOOK_URL:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    DISCORD_WEBHOOK_URL=$(grep -E '^DISCORD_WEBHOOK_URL=' "$SCRIPT_DIR/.env" \
        | head -1 | cut -d= -f2- | tr -d '"' || true)
fi

MAP_LOAD_TIMEOUT="${MAP_LOAD_TIMEOUT:-600}"

# ──────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────

log() { echo "[update-mods] $*"; }

send_discord() {
    local msg="$1"
    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        curl -s -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"content\": $(printf '%s' "$msg" | jq -Rs .)}" \
            && log "Discord notification sent." \
            || log "WARNING: Discord notification failed."
    else
        log "No DISCORD_WEBHOOK_URL set — skipping notification."
    fi
}

gh_api() {
    curl -sf \
        -H "Accept: application/vnd.github+json" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "$@"
}

installed_version() {
    local repo="$1"
    grep -E "^${repo}=" "$VERSIONS_FILE" 2>/dev/null | cut -d= -f2- || echo ""
}

save_version() {
    local repo="$1" tag="$2"
    touch "$VERSIONS_FILE"
    if grep -qE "^${repo}=" "$VERSIONS_FILE" 2>/dev/null; then
        sed -i "s|^${repo}=.*|${repo}=${tag}|" "$VERSIONS_FILE"
    else
        echo "${repo}=${tag}" >> "$VERSIONS_FILE"
    fi
}

# ──────────────────────────────────────────────────────────
# 1. Check for updates before touching the server
# ──────────────────────────────────────────────────────────

declare -A LATEST_TAGS
declare -A LATEST_ZIP_URLS
REPOS=(
    "AlienXAXS/StarRupture-ModLoader"
    "AlienXAXS/StarRupture-Plugin-KeepTicking"
    "AlienXAXS/StarRupture-Plugin-ServerUtility"
)

log "Checking for updates..."
UPDATES_AVAILABLE=false

for repo in "${REPOS[@]}"; do
    release_data=$(gh_api "https://api.github.com/repos/$repo/releases/latest")
    tag=$(echo "$release_data" | jq -r '.tag_name')
    zip_url=$(echo "$release_data" | jq -r '
        .assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -1)

    LATEST_TAGS["$repo"]="$tag"
    LATEST_ZIP_URLS["$repo"]="$zip_url"

    current=$(installed_version "$repo")
    if [ "$tag" != "$current" ]; then
        log "  $repo: $current → $tag (update available)"
        UPDATES_AVAILABLE=true
    else
        log "  $repo: $tag (already current)"
    fi
done

if [ "$UPDATES_AVAILABLE" = false ]; then
    log "All mods are up to date — nothing to do."
    exit 0
fi

# ──────────────────────────────────────────────────────────
# 2. Stop the server
# ──────────────────────────────────────────────────────────
log "Stopping server..."
$COMPOSE stop

# ──────────────────────────────────────────────────────────
# 3. Download and extract updated mods
# ──────────────────────────────────────────────────────────

extract_release() {
    local repo="$1"; shift
    local dest="$1"; shift
    local patterns=("$@")

    local tag="${LATEST_TAGS[$repo]}"
    local zip_url="${LATEST_ZIP_URLS[$repo]}"

    if [ -z "$zip_url" ]; then
        log "ERROR: No .zip asset found for $repo $tag — skipping."
        return 1
    fi

    log "Downloading $repo $tag ..."
    local tmpfile
    tmpfile=$(mktemp /tmp/starrupture-mod-XXXXXX.zip)
    trap 'rm -f "$tmpfile"' RETURN

    curl -sfL \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "$zip_url" -o "$tmpfile"

    mkdir -p "$dest"
    for pat in "${patterns[@]}"; do
        unzip -jo "$tmpfile" "$pat" -d "$dest" 2>/dev/null || true
    done

    save_version "$repo" "$tag"
    log "Extracted ${patterns[*]} → $dest"
}

# ModLoader — only dwmapi.dll (and its PDB) goes in the modloader root
extract_release \
    "AlienXAXS/StarRupture-ModLoader" \
    "$MODLOADER_DIR" \
    "*dwmapi.dll" "*dwmapi.pdb"

# KeepTicking plugin — DLL + PDB into Plugins/
extract_release \
    "AlienXAXS/StarRupture-Plugin-KeepTicking" \
    "$PLUGINS_DIR" \
    "*.dll" "*.pdb"

# ServerUtility plugin — DLL + JSON + PDB into Plugins/
extract_release \
    "AlienXAXS/StarRupture-Plugin-ServerUtility" \
    "$PLUGINS_DIR" \
    "*.dll" "*.json" "*.pdb"

# ──────────────────────────────────────────────────────────
# 4. Start the server
# ──────────────────────────────────────────────────────────
log "Starting server..."
$COMPOSE up -d

# ──────────────────────────────────────────────────────────
# 5. Wait for map load and verify ChimeraMain loaded
# ──────────────────────────────────────────────────────────
log "Waiting up to ${MAP_LOAD_TIMEOUT}s for server to load map..."

LAUNCH_EPOCH=$(date +%s)
WAITED=0
RESULT="timeout"

# Wait for a fresh log file (game rotates on start)
while [ $WAITED -lt 60 ]; do
    if [ -f "$LOG_FILE" ]; then
        LOG_MTIME=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
        [ "$LOG_MTIME" -ge "$LAUNCH_EPOCH" ] && break
    fi
    sleep 3
    WAITED=$((WAITED + 3))
done

if [ ! -f "$LOG_FILE" ]; then
    log "WARNING: Log file never appeared at $LOG_FILE"
fi

while [ $WAITED -lt "$MAP_LOAD_TIMEOUT" ]; do
    if [ -f "$LOG_FILE" ]; then
        if grep -qF "UEngine::LoadMap Load map complete /Game/Chimera/Maps/ChimeraMain/ChimeraMain" "$LOG_FILE"; then
            RESULT="ok"
            break
        fi
        if grep -qF "UEngine::LoadMap Load map complete /Game/Chimera/Maps/DedicatedServer" "$LOG_FILE"; then
            RESULT="wrong_map"
            break
        fi
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

# ──────────────────────────────────────────────────────────
# 6. Report result
# ──────────────────────────────────────────────────────────
case "$RESULT" in
    ok)
        log "SUCCESS: Server loaded ChimeraMain map correctly."
        ;;
    wrong_map)
        log "ERROR: Server loaded DedicatedServer map — bringing server down."
        $COMPOSE down
        send_discord \
            "🚨 **StarRupture mod update** — server loaded \`DedicatedServer\` map instead of \`ChimeraMain\` after mod update. Container has been stopped. Manual check required."
        exit 1
        ;;
    timeout)
        log "WARNING: Timed out after ${MAP_LOAD_TIMEOUT}s waiting for map load line in log."
        $COMPOSE down
        send_discord \
            "⚠️ **StarRupture mod update** — server did not confirm map load within ${MAP_LOAD_TIMEOUT}s. Container has been stopped. Manual check required."
        exit 1
        ;;
esac
