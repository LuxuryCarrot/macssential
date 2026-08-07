#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# macssential Local Uninstall
#
# Usage:
#   bash scripts/uninstall.sh
#
# Removes macssential.app from /Applications, resets its Accessibility (TCC)
# permission, and rebuilds the user/local LaunchServices database to clear
# dead registrations left behind by repeated ad-hoc-signed installs.
#
# macOS only (uses osascript, hdiutil, tccutil, lsregister).
# =============================================================================

# --- Configuration ---
APP_NAME="macssential"
BUNDLE_ID="com.macssential.macssential"
DEST="/Applications/${APP_NAME}.app"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# --- Logging helpers ---
log()  { echo "==> $*"; }
warn() { echo "    warning: $*" >&2; }

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

# --- Remove the app ---
if [ -d "$DEST" ]; then
    log "Removing $DEST"
    rm -rf "$DEST"
else
    log "${APP_NAME} is not installed at $DEST (nothing to remove)."
fi

# --- Reset Accessibility (TCC) permission ---
log "Resetting Accessibility permission for ${BUNDLE_ID}..."
tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null || true

# --- Clean up dead LaunchServices registrations ---
if [ -x "$LSREGISTER" ]; then
    log "Rebuilding LaunchServices database (this may take a moment)..."
    "$LSREGISTER" -kill -r -domain local -domain user 2>/dev/null || true
else
    warn "lsregister not found, skipping LaunchServices cleanup."
fi

# --- Done ---
echo ""
log "Uninstall complete."
