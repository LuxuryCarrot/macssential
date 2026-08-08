#!/bin/bash
set -euo pipefail

# =============================================================================
# publish-release.sh -- publish a release to the public distribution repos
#
# Usage:
#   bash scripts/publish-release.sh [path/to/macssential-X.Y.Z.dmg]
#
# Default DMG: newest build/macssential-*.dmg by mtime.
#
# Pipeline (requires an authenticated gh CLI -- run `gh auth login` first):
#   1. Create (or upload to) GitHub Release vX.Y.Z on LuxuryCarrot/macssential
#   2. Publish docs/appcast.xml as docs/appcast.xml on that repo's main branch
#      (GitHub Pages serves main branch /docs -> Sparkle feed)
#   3. Render packaging/homebrew/macssential.rb with version + sha256 and push
#      it to LuxuryCarrot/homebrew-tap as Casks/macssential.rb
#
# This script never sources local credential files and never prints tokens or
# secrets. All values it logs (version, URLs, sha256) are public metadata.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# --- Configuration ---
RELEASES_REPO="LuxuryCarrot/macssential"
TAP_REPO="LuxuryCarrot/homebrew-tap"
CASK_TEMPLATE="packaging/homebrew/macssential.rb"
APPCAST="docs/appcast.xml"
INFO_PLIST="macssential/macssential/Info.plist"

# --- Preflight: gh must be installed and authenticated ---
if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI is not installed (brew install gh)" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh CLI is not authenticated." >&2
    echo "Run 'gh auth login' first, then re-run this script." >&2
    exit 1
fi

# --- Preflight: required files exist ---
for f in "$CASK_TEMPLATE" "$APPCAST" "$INFO_PLIST"; do
    if [ ! -f "$f" ]; then
        echo "Error: required file not found: $f" >&2
        exit 1
    fi
done

# --- Resolve DMG path ---
if [ $# -ge 1 ]; then
    DMG_PATH="$1"
else
    DMG_PATH=$(ls -t build/macssential-*.dmg 2>/dev/null | head -1 || true)
    if [ -z "$DMG_PATH" ]; then
        echo "Error: no DMG found matching build/macssential-*.dmg" >&2
        echo "Build one first (scripts/build-release.sh) or pass a DMG path." >&2
        exit 1
    fi
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: DMG not found: $DMG_PATH" >&2
    exit 1
fi

# --- Read version from Info.plist ---
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")

# --- Sanity check: DMG filename must match repo version ---
EXPECTED_NAME="macssential-$VERSION.dmg"
ACTUAL_NAME="$(basename "$DMG_PATH")"
if [ "$ACTUAL_NAME" != "$EXPECTED_NAME" ]; then
    echo "Error: DMG filename '$ACTUAL_NAME' does not match Info.plist version '$VERSION'" >&2
    echo "Expected: $EXPECTED_NAME" >&2
    echo "The repo's Info.plist and the DMG disagree -- refusing to publish an" >&2
    echo "old artifact under a new version number. Rebuild or pass the right DMG." >&2
    exit 1
fi

# --- Sanity check: appcast already contains this version's public-URL item ---
if ! grep -q "v$VERSION/macssential-$VERSION.dmg" "$APPCAST"; then
    echo "Error: $APPCAST has no item for v$VERSION with the public download URL." >&2
    echo "Run 'bash scripts/update-appcast.sh $DMG_PATH' first, then retry." >&2
    exit 1
fi

# --- Helper: create-or-update a file in a GitHub repo via the contents API ---
# gh_put_file <repo> <path> <local_file> <commit_msg>
gh_put_file() {
    local repo="$1" path="$2" local_file="$3" commit_msg="$4"
    local content sha
    content=$(base64 < "$local_file" | tr -d '\n')
    sha=$(gh api "repos/$repo/contents/$path" --jq .sha 2>/dev/null || true)
    if [ -n "$sha" ]; then
        gh api --method PUT "repos/$repo/contents/$path" \
            -f message="$commit_msg" \
            -f content="$content" \
            -f branch=main \
            -f sha="$sha" >/dev/null
    else
        gh api --method PUT "repos/$repo/contents/$path" \
            -f message="$commit_msg" \
            -f content="$content" \
            -f branch=main >/dev/null
    fi
    echo "==> Pushed $path to $repo (main)"
}

# --- Step 1: GitHub Release upload with authoritative verification ---
# gh release upload has produced silently TRUNCATED assets on this machine
# (~1.1MB cutoff; v0.1.7 and v0.1.8 both shipped broken this way). A truncated
# asset breaks Sparkle's EdDSA validation on user machines ("update is
# improperly signed"). Two-layer defense:
#   1. API-reported asset size — authoritative, immune to CDN caching. A
#      download-back hash alone is NOT sufficient: after --clobber the CDN can
#      keep serving the previous (good) upload while the new truncated blob
#      propagates, making a hash check pass against stale bytes.
#   2. Download-back sha256 — confirms the CDN actually converged to the
#      verified blob before we publish the appcast pointing at it.
TAG="v$VERSION"
LOCAL_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
LOCAL_SIZE=$(stat -f %z "$DMG_PATH")
ASSET_URL="https://github.com/$RELEASES_REPO/releases/download/$TAG/$EXPECTED_NAME"

api_asset_size() {
    gh release view "$TAG" --repo "$RELEASES_REPO" --json assets \
        --jq ".assets[] | select(.name == \"$EXPECTED_NAME\") | .size" 2>/dev/null || true
}

cdn_hash_matches() {
    local tmp_dl i
    tmp_dl=$(mktemp)
    # Poll until the CDN serves the verified blob (propagation can lag).
    for i in $(seq 1 18); do
        if curl -fsSL "$ASSET_URL" -o "$tmp_dl" \
            && [ "$(shasum -a 256 "$tmp_dl" | awk '{print $1}')" = "$LOCAL_SHA" ]; then
            rm -f "$tmp_dl"
            return 0
        fi
        sleep 10
    done
    rm -f "$tmp_dl"
    return 1
}

if ! gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
    echo "==> Creating release $TAG on $RELEASES_REPO (no asset yet)..."
    gh release create "$TAG" --repo "$RELEASES_REPO" \
        --title "macssential $VERSION" \
        --notes "macssential $VERSION"
fi

if [ "$(api_asset_size)" = "$LOCAL_SIZE" ] && cdn_hash_matches; then
    # Asset already correct end-to-end -- do NOT clobber (a needless re-upload
    # is exactly what corrupted v0.1.8).
    echo "==> Asset already verified on $TAG -- skipping upload."
else
    UPLOAD_OK=false
    for attempt in 1 2 3; do
        echo "==> Uploading DMG to $TAG (attempt $attempt/3)..."
        # Remove any existing (possibly truncated) asset first so a failed
        # upload can't hide behind a stale one.
        gh release delete-asset "$TAG" "$EXPECTED_NAME" --repo "$RELEASES_REPO" --yes 2>/dev/null || true
        gh release upload "$TAG" "$DMG_PATH" --repo "$RELEASES_REPO" || { sleep 5; continue; }
        API_SIZE=$(api_asset_size)
        if [ "$API_SIZE" = "$LOCAL_SIZE" ]; then
            echo "    API size verified: $API_SIZE bytes"
            UPLOAD_OK=true
            break
        fi
        echo "    API size mismatch: got '${API_SIZE:-none}', want $LOCAL_SIZE -- retrying..."
        sleep 5
    done
    if [ "$UPLOAD_OK" != "true" ]; then
        echo "Error: asset upload failed API size verification after 3 attempts." >&2
        echo "Aborting BEFORE publishing the appcast -- users would hit Sparkle signature errors." >&2
        exit 1
    fi
    echo "==> Waiting for CDN to serve the verified blob..."
    if ! cdn_hash_matches; then
        echo "Error: CDN did not converge to the verified asset within 3 minutes." >&2
        echo "Aborting BEFORE publishing the appcast. Re-run this script to retry." >&2
        exit 1
    fi
fi
echo "    Asset integrity verified (size $LOCAL_SIZE, sha256 $LOCAL_SHA)"

# --- Step 2: Publish appcast.xml as docs/appcast.xml (Pages serves main /docs) ---
echo "==> Publishing docs/appcast.xml to $RELEASES_REPO..."
gh_put_file "$RELEASES_REPO" "docs/appcast.xml" "$APPCAST" "Update appcast for macssential $VERSION"

# --- Step 3: Render and push Homebrew cask ---
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
RENDERED=$(mktemp)
trap 'rm -f "$RENDERED"' EXIT
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA256/g" "$CASK_TEMPLATE" > "$RENDERED"

echo "==> Publishing Homebrew cask to $TAP_REPO..."
gh_put_file "$TAP_REPO" "Casks/macssential.rb" "$RENDERED" "macssential $VERSION"

# --- Summary (public values only) ---
echo ""
echo "==> Publish complete"
echo "    Version:  $VERSION"
echo "    Release:  https://github.com/$RELEASES_REPO/releases/tag/$TAG"
echo "    Appcast:  https://luxurycarrot.github.io/macssential/appcast.xml"
echo "    Cask:     $TAP_REPO -> Casks/macssential.rb (sha256 $SHA256)"
