#!/bin/bash
# =============================================================================
# sparkle-tools.sh -- shared Sparkle CLI tool helpers
#
# This file is meant to be SOURCED, not executed:
#   source "$SCRIPT_DIR/lib/sparkle-tools.sh"
#
# Provides:
#   locate_sign_update -- echoes the absolute path to a usable sign_update
#     binary on stdout, or returns non-zero. All progress/informational
#     messages go to STDERR so callers can capture stdout as the path:
#       SIGN_UPDATE=$(locate_sign_update)
#
# Search order:
#   1. Cached copy in scripts/.sparkle-tools/bin/sign_update
#   2. Xcode DerivedData
#   3. Vendored Sparkle.framework under the repo's macssential/ directory
#   4. Download Sparkle release tarball and cache its bin/ directory
# =============================================================================

# Cache dir lives next to this library: scripts/.sparkle-tools/
SPARKLE_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.sparkle-tools"
SPARKLE_TOOLS_VERSION="2.8.0"

locate_sign_update() {
    local cached="$SPARKLE_TOOLS_DIR/bin/sign_update"
    local candidate=""

    # 1. Cached copy
    if [ -f "$cached" ]; then
        chmod +x "$cached" 2>/dev/null || true
        if [ -x "$cached" ]; then
            echo "    Using cached sign_update: $cached" >&2
            echo "$cached"
            return 0
        fi
    fi

    # 2. DerivedData
    candidate=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -type f 2>/dev/null | head -1)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        echo "    Using sign_update from DerivedData: $candidate" >&2
        echo "$candidate"
        return 0
    fi

    # 3. Vendored Sparkle.framework under the repo's macssential/ directory
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    candidate=$(find "$repo_root/macssential" -path "*Sparkle.framework*" -name sign_update -type f 2>/dev/null | head -1)
    if [ -n "$candidate" ]; then
        chmod +x "$candidate" 2>/dev/null || true
        if [ -x "$candidate" ]; then
            echo "    Using sign_update from vendored framework: $candidate" >&2
            echo "$candidate"
            return 0
        fi
    fi

    # 4. Download fallback -> cache bin/ wholesale into scripts/.sparkle-tools/
    echo "    sign_update not found locally, downloading Sparkle $SPARKLE_TOOLS_VERSION..." >&2
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -fsSL -o "$tmp_dir/Sparkle.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_TOOLS_VERSION/Sparkle-$SPARKLE_TOOLS_VERSION.tar.xz" \
        && tar -xJf "$tmp_dir/Sparkle.tar.xz" -C "$tmp_dir" \
        && [ -f "$tmp_dir/bin/sign_update" ]; then
        mkdir -p "$SPARKLE_TOOLS_DIR"
        # sign_update may rely on sibling tools; cache the whole bin/ directory
        cp -R "$tmp_dir/bin" "$SPARKLE_TOOLS_DIR/"
        chmod +x "$cached"
        rm -rf "$tmp_dir"
        echo "    Cached Sparkle tools in $SPARKLE_TOOLS_DIR/bin/" >&2
        echo "$cached"
        return 0
    fi

    rm -rf "$tmp_dir"
    echo "    Warning: failed to download/extract Sparkle $SPARKLE_TOOLS_VERSION" >&2
    return 1
}
