#!/bin/bash
set -euo pipefail

# =============================================================================
# macssential Build & Release Pipeline
#
# Usage:
#   bash scripts/build-release.sh
#
# Environment variables (all optional):
#   DEVELOPER_ID_APPLICATION  - Certificate identity for code signing
#   APPLE_ID                  - Apple ID for notarization
#   APPLE_TEAM_ID             - Apple Developer Team ID for notarization
#   APP_SPECIFIC_PASSWORD     - App-specific password for notarization
#   SPARKLE_EDDSA_KEY         - Sparkle EdDSA private key for update signing
#
# These can be exported in the shell, or provided via a git-ignored
# .env.release file in the project root (see .env.release.example).
#
# Without signing env vars, produces an unsigned DMG suitable for
# GitHub Releases distribution.
# =============================================================================

# --- Optional credentials file ---
# If .env.release exists in the project root, source it (exported via set -a).
# Precedence: values in .env.release OVERRIDE any pre-exported shell env vars
# for the variables it sets. Delete or comment out a line in .env.release to
# fall back to shell env. The file is git-ignored; see .env.release.example.
if [ -f ".env.release" ]; then
    echo "==> Loading credentials from .env.release"
    set -a
    # shellcheck disable=SC1091
    source ".env.release"
    set +a
fi

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/sparkle-tools.sh"

APP_NAME="macssential"
SCHEME="macssential"
PROJECT_DIR="macssential"
XCODEPROJ="$PROJECT_DIR/macssential.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
ENTITLEMENTS="$PROJECT_DIR/$APP_NAME/$APP_NAME.entitlements"

# --- Environment variables (optional, gated) ---
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APP_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD:-}"
SPARKLE_EDDSA_KEY="${SPARKLE_EDDSA_KEY:-}"

# --- Pre-flight checks ---

# Must run from project root
if [ ! -d "$XCODEPROJ" ]; then
    echo "Error: $XCODEPROJ not found."
    echo "This script must be run from the project root directory."
    exit 1
fi

# Check create-dmg dependency
if ! command -v create-dmg &>/dev/null; then
    echo "Error: create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

# --- Extract version from Info.plist ---
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/$APP_NAME/Info.plist")
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building $APP_NAME v$VERSION"
echo ""

# --- Step 1: Clean build directory ---
echo "==> Step 1: Cleaning build directory and DerivedData..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Purge stale macssential DerivedData clones (worktree builds leave one per path)
for DD_DIR in "$HOME/Library/Developer/Xcode/DerivedData"/macssential-*; do
    if [ -d "$DD_DIR" ]; then
        echo "    Removing stale DerivedData: $DD_DIR"
        rm -rf "$DD_DIR"
    fi
done

# --- Step 2: Archive (unsigned by default) ---
echo "==> Step 2: Archiving..."
xcodebuild archive \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

# --- Step 3: Extract .app from archive ---
echo "==> Step 3: Extracting .app from archive..."
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$APP_PATH"

# --- Step 4: Optional code signing (inside-out: Sparkle nested -> framework -> app) ---
if [ -n "$DEVELOPER_ID_APPLICATION" ]; then
    echo "==> Step 4: Code signing (inside-out)..."

    SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE_FW" ]; then
        # 1. Innermost first: Autoupdate binary, Updater.app, XPC services.
        #    NOTE: no --entitlements here -- app entitlements on Sparkle's XPC
        #    services break notarization/execution.
        SPARKLE_NESTED=(
            "$SPARKLE_FW/Versions/B/Autoupdate"
            "$SPARKLE_FW/Versions/B/Updater.app"
            "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
            "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
        )
        for NESTED in "${SPARKLE_NESTED[@]}"; do
            if [ -e "$NESTED" ]; then
                echo "    Signing $(basename "$NESTED")..."
                codesign --force --options runtime \
                    --sign "$DEVELOPER_ID_APPLICATION" \
                    "$NESTED"
            else
                echo "    Warning: $NESTED not found, skipping (Sparkle layout may differ)"
            fi
        done

        # 2. The framework itself
        echo "    Signing Sparkle.framework..."
        codesign --force --options runtime \
            --sign "$DEVELOPER_ID_APPLICATION" \
            "$SPARKLE_FW"
    else
        echo "    Warning: Sparkle.framework not found at $SPARKLE_FW"
    fi

    # 3. Finally the app itself (entitlements only here)
    echo "    Signing $APP_NAME.app..."
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEVELOPER_ID_APPLICATION" \
        "$APP_PATH"

    echo "    Verifying signature..."
    codesign --verify --deep --strict "$APP_PATH"
else
    echo "==> Step 4: Ad-hoc signing (no DEVELOPER_ID_APPLICATION set)..."

    SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE_FW" ]; then
        # 1. Innermost first: Autoupdate binary, Updater.app, XPC services.
        #    NOTE: no --entitlements here -- app entitlements on Sparkle's XPC
        #    services break execution (same rationale as Developer ID path).
        SPARKLE_NESTED=(
            "$SPARKLE_FW/Versions/B/Autoupdate"
            "$SPARKLE_FW/Versions/B/Updater.app"
            "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
            "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
        )
        for NESTED in "${SPARKLE_NESTED[@]}"; do
            if [ -e "$NESTED" ]; then
                echo "    Ad-hoc signing $(basename "$NESTED")..."
                codesign --force --sign - "$NESTED"
            else
                echo "    Warning: $NESTED not found, skipping (Sparkle layout may differ)"
            fi
        done

        # 2. The framework itself
        echo "    Ad-hoc signing Sparkle.framework..."
        codesign --force --sign - "$SPARKLE_FW"
    else
        echo "    Warning: Sparkle.framework not found at $SPARKLE_FW"
    fi

    # 3. Finally the app itself (entitlements only here) -- a full bundle
    #    signature (Identifier, Info.plist bound, sealed resources) is required
    #    for TCC to durably associate permission grants with the app.
    echo "    Ad-hoc signing $APP_NAME.app..."
    codesign --force --sign - \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH"

    echo "    Verifying signature..."
    codesign --verify --deep --strict "$APP_PATH"
fi

# --- Step 5: Optional notarization ---
if [ -n "$DEVELOPER_ID_APPLICATION" ] && [ -n "$APPLE_ID" ]; then
    echo "==> Step 5: Notarizing..."
    ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/$APP_NAME.zip"
    xcrun notarytool submit "$BUILD_DIR/$APP_NAME.zip" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "$APP_PATH"
    rm -f "$BUILD_DIR/$APP_NAME.zip"
else
    echo "==> Step 5: Skipping notarization (credentials not set)"
fi

# --- Step 6: Create DMG ---
echo "==> Step 6: Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"

# Ensure Finder is running (required for create-dmg AppleScript styling)
open -a Finder || true
sleep 1

# Remove any previous DMG (create-dmg won't overwrite)
rm -f "$DMG_PATH"

BG_IMAGE="$SCRIPT_DIR/dmg-background.png"
BG_IMAGE_2X="$SCRIPT_DIR/dmg-background@2x.png"

CREATE_DMG_EXIT=0
create-dmg \
    --volname "$APP_NAME" \
    --background "$BG_IMAGE" \
    --window-pos 200 120 \
    --window-size 540 340 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 140 130 \
    --app-drop-link 400 130 \
    --text-size 14 \
    --hide-extension "$APP_NAME.app" \
    "$DMG_PATH" \
    "$DMG_STAGING/" \
    || CREATE_DMG_EXIT=$?

# Exit code 2 = no Retina image (expected, non-fatal)
if [ $CREATE_DMG_EXIT -ne 0 ] && [ $CREATE_DMG_EXIT -ne 2 ]; then
    if [ ! -f "$DMG_PATH" ]; then
        echo "    create-dmg styling failed (exit $CREATE_DMG_EXIT), retrying..."
        sleep 2
        create-dmg \
            --volname "$APP_NAME" \
            --background "$BG_IMAGE" \
            --window-pos 200 120 \
            --window-size 540 340 \
            --icon-size 128 \
            --icon "$APP_NAME.app" 140 155 \
            --app-drop-link 400 155 \
            --text-size 14 \
            --hide-extension "$APP_NAME.app" \
            "$DMG_PATH" \
            "$DMG_STAGING/" \
            || CREATE_DMG_EXIT=$?

        # Final fallback: hdiutil (no Finder styling, but functional)
        if [ ! -f "$DMG_PATH" ]; then
            echo "    create-dmg retry failed, falling back to hdiutil (no styling)..."
            ln -sf /Applications "$DMG_STAGING/Applications"
            hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" \
                -ov -format UDZO "$DMG_PATH"
        fi
    else
        echo "    create-dmg warning (exit $CREATE_DMG_EXIT), DMG was still created"
    fi
fi

rm -rf "$DMG_STAGING"

# --- Step 7: Optional DMG sign + notarize + staple ---
# The app zip notarization in Step 5 covers the app bundle only; the DMG
# needs its OWN signature and notarization ticket before it can be stapled
# (unsigned/un-notarized DMG -> stapler Error 65).
if [ -n "$DEVELOPER_ID_APPLICATION" ] && [ -n "$APPLE_ID" ]; then
    echo "==> Step 7: Signing, notarizing, and stapling DMG..."
    codesign --force --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "$DMG_PATH"
else
    echo "==> Step 7: Skipping DMG sign/notarize/staple (credentials not set)"
fi

# --- Step 7b: Sparkle EdDSA signing ---
# Always attempted. If SPARKLE_EDDSA_KEY is set (CI), a 0600 temp key file is
# used; otherwise sign_update reads the EdDSA key from the login Keychain
# automatically. Failure is non-fatal so unsigned test builds still succeed.
echo "==> Step 7b: Signing DMG with Sparkle EdDSA..."

SIGN_UPDATE=$(locate_sign_update) || SIGN_UPDATE=""

if [ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ]; then
    if [ -n "$SPARKLE_EDDSA_KEY" ]; then
        # File-based key wins (needed for CI).
        # Write the private key to a 0600 temp file, guaranteed cleanup via trap
        KEY_FILE=$(umask 077 && mktemp)
        trap 'rm -f "$KEY_FILE"' EXIT
        printf '%s' "$SPARKLE_EDDSA_KEY" > "$KEY_FILE"

        if "$SIGN_UPDATE" "$DMG_PATH" --ed-key-file "$KEY_FILE" > "$BUILD_DIR/eddsa-signature.txt"; then
            echo "    EdDSA signature written to $BUILD_DIR/eddsa-signature.txt"
            echo "    $(cat "$BUILD_DIR/eddsa-signature.txt")"
        else
            echo "    Warning: sign_update failed; no EdDSA signature produced"
            rm -f "$BUILD_DIR/eddsa-signature.txt"
        fi

        rm -f "$KEY_FILE"
        trap - EXIT
    else
        echo "    Using EdDSA key from login Keychain"
        if "$SIGN_UPDATE" "$DMG_PATH" > "$BUILD_DIR/eddsa-signature.txt"; then
            echo "    EdDSA signature written to $BUILD_DIR/eddsa-signature.txt"
            echo "    $(cat "$BUILD_DIR/eddsa-signature.txt")"
        else
            echo "    Warning: sign_update failed; no EdDSA signature produced"
            rm -f "$BUILD_DIR/eddsa-signature.txt"
        fi
    fi
else
    echo "    Warning: sign_update unavailable, skipping EdDSA signing"
fi

# --- Step 8: Summary ---
echo ""
echo "==> Build complete!"
echo "    DMG: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
if [ -n "$DEVELOPER_ID_APPLICATION" ]; then
    echo "    Signed: Yes"
else
    echo "    Signed: Ad-hoc (no Developer ID)"
fi
if [ -n "$DEVELOPER_ID_APPLICATION" ] && [ -n "$APPLE_ID" ]; then
    echo "    Notarized: Yes"
else
    echo "    Notarized: No"
fi
if [ -s "$BUILD_DIR/eddsa-signature.txt" ]; then
    echo "    Sparkle EdDSA: Yes"
else
    echo "    Sparkle EdDSA: No"
fi
