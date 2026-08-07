#!/bin/bash
set -euo pipefail

# =============================================================================
# macssential Dev Clean
#
# Removes development build residue that pollutes Spotlight and TCC:
#   - Stale DerivedData clones (one per worktree build path), each containing
#     a Debug macssential.app that shows up as a duplicate in Spotlight
#   - The repo-local build/ directory
#
# Modes:
#   (default)       Kill dev instances (NOT /Applications copy), remove
#                   ~/Library/Developer/Xcode/DerivedData/macssential-* and
#                   the repo build/ dir. TCC permissions untouched.
#   --permissions   Additionally reset Accessibility + AppleEvents TCC grants
#                   for com.macssential.macssential (re-grant needed on next
#                   launch of the installed app).
#   --all           Uninstall-grade clean: everything above PLUS remove
#                   /Applications/macssential.app, preferences, caches, logs,
#                   HTTP storage, and Application Support data. Requires
#                   explicit confirmation unless --yes is passed.
#                   Implies --permissions.
#   --yes           Skip the --all confirmation prompt.
#   --help          Show this usage.
# =============================================================================

readonly APP_NAME="macssential"
readonly BUNDLE_ID="com.macssential.macssential"
readonly DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly REPO_ROOT

usage() {
    cat <<'EOF'
Usage: scripts/dev-clean.sh [--permissions] [--all] [--yes] [--help]

Modes:
  (default)      Remove stale macssential DerivedData clones and repo build/.
                 Kills dev app instances but preserves /Applications copy and
                 all TCC permissions.
  --permissions  Also reset Accessibility and AppleEvents TCC grants for
                 com.macssential.macssential (you must re-grant on next launch).
  --all          Full uninstall-grade clean: removes /Applications/macssential.app,
                 preferences, caches, logs, and app data. Implies --permissions.
                 Prompts for confirmation unless --yes is given.
  --yes          Skip the --all confirmation prompt.
  --help         Show this help.
EOF
}

RESET_PERMISSIONS=false
FULL_CLEAN=false
ASSUME_YES=false

for arg in "$@"; do
    case "$arg" in
        --permissions) RESET_PERMISSIONS=true ;;
        --all)         FULL_CLEAN=true; RESET_PERMISSIONS=true ;;
        --yes)         ASSUME_YES=true ;;
        --help|-h)     usage; exit 0 ;;
        *)             echo "Error: unknown flag '$arg'"; echo ""; usage; exit 1 ;;
    esac
done

# --- Confirmation gate for --all ---
if [ "$FULL_CLEAN" = true ] && [ "$ASSUME_YES" != true ]; then
    read -r -p "This will REMOVE /Applications/macssential.app and all app data. Type 'yes' to continue: " REPLY
    if [ "$REPLY" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "==> macssential dev clean"

# --- Step 1: Kill running instances ---
if [ "$FULL_CLEAN" = true ]; then
    echo "==> Quitting installed app and killing all instances..."
    osascript -e 'quit app "macssential"' 2>/dev/null || true
    sleep 1
fi

KILLED_COUNT=0
for PID in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do
    EXE_PATH="$(ps -o comm= -p "$PID" 2>/dev/null || true)"
    [ -n "$EXE_PATH" ] || continue
    if [ "$FULL_CLEAN" = true ]; then
        echo "    Killing PID $PID ($EXE_PATH)"
        kill "$PID" 2>/dev/null || true
        KILLED_COUNT=$((KILLED_COUNT + 1))
    else
        case "$EXE_PATH" in
            /Applications/macssential.app/*)
                echo "    Preserving installed app instance (PID $PID)"
                ;;
            *)
                echo "    Killing dev instance PID $PID ($EXE_PATH)"
                kill "$PID" 2>/dev/null || true
                KILLED_COUNT=$((KILLED_COUNT + 1))
                ;;
        esac
    fi
done

# --- Step 2: Remove stale DerivedData clones ---
echo "==> Removing stale DerivedData clones..."
DD_REMOVED=0
for dir in "$DERIVED_DATA_DIR"/macssential-*; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in
        macssential-*)
            echo "    Removing $dir"
            rm -rf "$dir"
            DD_REMOVED=$((DD_REMOVED + 1))
            ;;
        *)
            echo "    Skipping unexpected path: $dir"
            ;;
    esac
done

# --- Step 3: Remove repo build artifacts ---
BUILD_REMOVED="not present"
if [ -e "$REPO_ROOT/scripts/build-release.sh" ]; then
    if [ -d "$REPO_ROOT/build" ]; then
        echo "==> Removing repo build directory: $REPO_ROOT/build"
        rm -rf "$REPO_ROOT/build"
        BUILD_REMOVED="removed"
    fi
else
    echo "    Warning: $REPO_ROOT does not look like the macssential repo; skipping build/ removal"
    BUILD_REMOVED="skipped (repo sanity check failed)"
fi

# --- Step 4: Optional TCC permission reset ---
if [ "$RESET_PERMISSIONS" = true ]; then
    echo "==> Resetting TCC permissions for $BUNDLE_ID..."
    echo "    WARNING: the installed app will lose its Accessibility and"
    echo "    Automation grants. You must re-grant them on next launch."
    tccutil reset Accessibility com.macssential.macssential || echo "    warning: tccutil reset Accessibility failed"
    tccutil reset AppleEvents com.macssential.macssential || echo "    warning: tccutil reset AppleEvents failed"
fi

# --- Step 5: Full uninstall (--all) ---
if [ "$FULL_CLEAN" = true ]; then
    echo "==> Full uninstall: removing installed app and app data..."

    if [ -d "/Applications/macssential.app" ]; then
        echo "    Removing /Applications/macssential.app"
        rm -rf "/Applications/macssential.app"
    fi

    defaults delete com.macssential.macssential 2>/dev/null || true

    ALL_DATA_PATHS=(
        "$HOME/Library/HTTPStorages/com.macssential.macssential"
        "$HOME/Library/Caches/com.macssential.macssential"
        "$HOME/Library/Application Support/macssential"
        "$HOME/Library/Application Support/com.macssential.macssential"
        "$HOME/Library/Logs/macssential"
        "$HOME/Library/Logs/com.macssential.macssential"
        "$HOME/Library/Preferences/com.macssential.macssential.plist"
    )
    for path in "${ALL_DATA_PATHS[@]}"; do
        if [ -e "$path" ]; then
            echo "    Removing $path"
            rm -rf "$path"
        fi
    done
fi

# --- Summary ---
echo ""
echo "==> Clean complete"
echo "    Dev instances killed:      $KILLED_COUNT"
echo "    DerivedData dirs removed:  $DD_REMOVED"
echo "    Repo build/ directory:     $BUILD_REMOVED"
if [ "$RESET_PERMISSIONS" = true ]; then
    echo "    TCC permissions:           reset (Accessibility, AppleEvents)"
else
    echo "    TCC permissions:           untouched"
fi
if [ "$FULL_CLEAN" = true ]; then
    echo "    Installed app + app data:  removed"
else
    echo "    /Applications app:         untouched"
fi
