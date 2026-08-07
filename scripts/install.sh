#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# macssential Local Install
#
# Usage:
#   bash scripts/install.sh [path/to/macssential.app]
#
# Installs a single clean copy of macssential.app into /Applications.
# Idempotent: if the installed copy already matches the source (same code
# signature CDHash), the copy is skipped. Otherwise the existing install is
# removed and replaced.
#
# When no source path is given, the newest dated build under build/ that
# contains macssential.app is used, falling back to build/macssential.app.
#
# macOS only (uses osascript, hdiutil, xattr, lsregister, codesign).
# =============================================================================

# --- Configuration ---
APP_NAME="macssential"
BUNDLE_ID="com.macssential.macssential"
DEST="/Applications/${APP_NAME}.app"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# --- Logging helpers ---
log()  { echo "==> $*"; }
warn() { echo "    warning: $*" >&2; }

# --- Resolve source .app ---
resolve_source() {
    # Explicit argument wins.
    if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
        if [ -d "$1" ]; then
            ( cd "$1" && pwd )
            return 0
        fi
        log "Error: source path not found: $1"
        exit 1
    fi

    # Scan build/*/ dated dirs, highest-sorting (newest) first.
    if [ -d "$ROOT/build" ]; then
        local dir
        for dir in $(ls -d "$ROOT"/build/*/ 2>/dev/null | sort -r); do
            if [ -d "${dir}${APP_NAME}.app" ]; then
                ( cd "${dir}${APP_NAME}.app" && pwd )
                return 0
            fi
        done
    fi

    # Fallback: build/macssential.app
    if [ -d "$ROOT/build/${APP_NAME}.app" ]; then
        ( cd "$ROOT/build/${APP_NAME}.app" && pwd )
        return 0
    fi

    log "Error: no ${APP_NAME}.app found."
    echo "    Build one first:  bash scripts/build-release.sh"
    echo "    Or pass a path:   bash scripts/install.sh path/to/${APP_NAME}.app"
    exit 1
}

SRC="$(resolve_source "$@")"
log "Source: $SRC"

# --- Quit running app ---
log "Quitting running ${APP_NAME} (if any)..."
osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1

# --- Detach mounted macssential DMG volumes ---
detach_dmg_volumes() {
    local vol
    for vol in /Volumes/${APP_NAME}* /Volumes/dmg.*; do
        [ -d "$vol" ] || continue
        if [ -d "$vol/${APP_NAME}.app" ]; then
            log "Detaching DMG volume: $vol"
            hdiutil detach "$vol" -force 2>/dev/null || true
        fi
    done
}
detach_dmg_volumes

# --- Read CDHash from a bundle ---
cdhash_of() {
    codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}'
}

# --- Idempotent install ---
if [ -d "$DEST" ]; then
    SRC_HASH="$(cdhash_of "$SRC" || true)"
    DEST_HASH="$(cdhash_of "$DEST" || true)"
    if [ -n "$SRC_HASH" ] && [ "$SRC_HASH" = "$DEST_HASH" ]; then
        log "Installed copy is identical (CDHash $SRC_HASH) -- skipping copy."
    else
        log "Replacing existing install at $DEST"
        rm -rf "$DEST"
        cp -R "$SRC" "$DEST"
        log "Copied to $DEST"
    fi
else
    log "Installing to $DEST"
    cp -R "$SRC" "$DEST"
    log "Copied to $DEST"
fi

# --- Strip quarantine ---
log "Removing quarantine attribute..."
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# --- Re-register with LaunchServices ---
if [ -x "$LSREGISTER" ]; then
    log "Registering with LaunchServices..."
    "$LSREGISTER" -f "$DEST" 2>/dev/null || true
else
    warn "lsregister not found, skipping LaunchServices registration."
fi

# --- Done ---
echo ""
log "Install complete: $DEST"
echo "    If Accessibility permission misbehaves after an update, run:"
echo "      tccutil reset Accessibility ${BUNDLE_ID}"
echo "    then re-grant permission in System Settings > Privacy & Security > Accessibility."
