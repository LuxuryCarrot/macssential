#!/bin/bash
set -euo pipefail

# =============================================================================
# update-appcast.sh -- generate/replace a release <item> in docs/appcast.xml
#
# Usage:
#   bash scripts/update-appcast.sh [path/to/macssential-X.Y.Z.dmg]
#
# Default DMG: newest build/macssential-*.dmg by mtime.
#
# Signs the DMG with Sparkle's sign_update (EdDSA key read from the login
# Keychain automatically -- no key material is handled by this script),
# computes metadata, and inserts or replaces the matching <item> in
# docs/appcast.xml. Idempotent: re-running for the same version replaces
# the existing item instead of duplicating it.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/sparkle-tools.sh"
cd "$SCRIPT_DIR/.."

INFO_PLIST="macssential/macssential/Info.plist"
APPCAST="docs/appcast.xml"

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

# --- Read version info from Info.plist ---
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")

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

# --- Locate sign_update (required here, unlike build-release.sh) ---
SIGN_UPDATE=$(locate_sign_update) || {
    echo "Error: sign_update unavailable -- cannot sign the update" >&2
    exit 1
}

# --- Sign (login Keychain key is used automatically; nothing secret is read
#     or printed by this script -- the signature line is public) ---
echo "==> Signing $DMG_PATH with Sparkle EdDSA (login Keychain)..."
SIG_LINE=$("$SIGN_UPDATE" "$DMG_PATH")
if [ -z "$SIG_LINE" ] || [[ "$SIG_LINE" != *'sparkle:edSignature="'* ]]; then
    echo "Error: sign_update produced no usable signature line" >&2
    exit 1
fi

ED_SIGNATURE=$(printf '%s' "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(printf '%s' "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

if [ -z "$ED_SIGNATURE" ] || [ -z "$LENGTH" ]; then
    echo "Error: failed to parse edSignature/length from sign_update output" >&2
    exit 1
fi

# --- Cross-check length against actual file size ---
ACTUAL_SIZE=$(stat -f%z "$DMG_PATH")
if [ "$LENGTH" != "$ACTUAL_SIZE" ]; then
    echo "Error: sign_update length ($LENGTH) != actual DMG size ($ACTUAL_SIZE)" >&2
    exit 1
fi

# --- Build the new <item> block ---
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

ITEM_XML="    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url=\"https://github.com/LuxuryCarrot/macssential/releases/download/v$VERSION/macssential-$VERSION.dmg\"
        sparkle:edSignature=\"$ED_SIGNATURE\"
        length=\"$LENGTH\"
        type=\"application/octet-stream\" />
    </item>"

# --- Insert/replace item in appcast.xml (backup + validate + restore) ---
BACKUP=$(mktemp)
cp "$APPCAST" "$BACKUP"

export APPCAST_VERSION="$VERSION"
export APPCAST_ITEM="$ITEM_XML"
export APPCAST_PATH="$APPCAST"

if ! python3 <<'PY'
import os, re, sys

path = os.environ["APPCAST_PATH"]
version = os.environ["APPCAST_VERSION"]
item = os.environ["APPCAST_ITEM"]

src = open(path, encoding="utf-8").read()

# Mask comment regions so we only match NON-commented <item> blocks,
# while keeping original offsets intact.
masked = list(src)
for m in re.finditer(r"<!--.*?-->", src, re.DOTALL):
    for i in range(m.start(), m.end()):
        masked[i] = "\x00"
masked = "".join(masked)

# Find an existing uncommented <item> block for this version.
target = None
for m in re.finditer(r"<item>.*?</item>", masked, re.DOTALL):
    block = src[m.start():m.end()]
    vm = re.search(
        r"<sparkle:shortVersionString>\s*([^<]+?)\s*</sparkle:shortVersionString>",
        block,
    )
    if vm and vm.group(1) == version:
        target = m
        break

if target:
    # Replace existing block (expand to full indented lines).
    start = src.rfind("\n", 0, target.start()) + 1
    end = target.end()
    new_src = src[:start] + item + src[end:]
else:
    # Insert immediately after the closing --> of the template comment block,
    # before </channel>.
    close = src.rfind("-->", 0, src.find("</channel>"))
    if close == -1:
        sys.stderr.write("template comment block not found in appcast\n")
        sys.exit(1)
    insert_at = src.find("\n", close) + 1
    new_src = src[:insert_at] + item + "\n" + src[insert_at:]

open(path, "w", encoding="utf-8").write(new_src)
PY
then
    echo "Error: appcast edit failed; restoring original" >&2
    cp "$BACKUP" "$APPCAST"
    rm -f "$BACKUP"
    exit 1
fi

# --- Validate resulting XML; restore backup on failure ---
if ! python3 -c "import xml.dom.minidom; xml.dom.minidom.parse('$APPCAST')" 2>/dev/null; then
    echo "Error: $APPCAST is not valid XML after edit; restoring original" >&2
    cp "$BACKUP" "$APPCAST"
    rm -f "$BACKUP"
    exit 1
fi
rm -f "$BACKUP"

# --- Summary (edSignature is public -- safe to log) ---
echo ""
echo "==> Appcast updated: $APPCAST"
echo "    Version:     $VERSION"
echo "    Build:       $BUILD"
echo "    edSignature: $ED_SIGNATURE"
echo "    Length:      $LENGTH"
echo "    pubDate:     $PUB_DATE"
