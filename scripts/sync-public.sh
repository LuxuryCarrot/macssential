#!/bin/bash
set -euo pipefail

# =============================================================================
# sync-public.sh -- snapshot-sync build-necessary source to the public repo
#
# Usage:
#   bash scripts/sync-public.sh
#
# Snapshot-syncs the build-necessary source of this development repo to the
# public repo (LuxuryCarrot/macssential). It never touches the private repo's
# history -- the public repo receives flat snapshot commits only. Safe to
# re-run: when nothing changed, it exits without committing.
#
# What gets synced (explicit allowlist):
#   macssential/   (Xcode project, incl. vendored Sparkle.framework)
#   scripts/       (minus .sparkle-tools cache)
#   packaging/     (minus releases-repo -- its READMEs go to the clone root)
#   docs/          (GitHub Pages / Sparkle appcast)
#   .github/       (FUNDING.yml)
#   LICENSE, .gitignore, .env.release.example
#   packaging/releases-repo/README*.md -> clone root README*.md
#
# Never synced: .planning, .claude, CLAUDE.md, .env.release, build/,
# xcuserdata, .git, .sparkle-tools, .DS_Store, *.profraw.
#
# This script never sources local credential files and never prints tokens or
# secrets.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# --- Configuration ---
PUBLIC_REPO="LuxuryCarrot/macssential"

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

# --- Clone the public repo into a throwaway workdir ---
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

CLONE="$WORK_DIR/public"
if ! gh repo clone "$PUBLIC_REPO" "$CLONE" -- --depth 1; then
    echo "Error: failed to clone $PUBLIC_REPO" >&2
    exit 1
fi

# Ensure we are on main. Works both for an empty repo (no commits yet) and
# for an existing main -- this is a fresh throwaway clone of the tip, so
# resetting the branch pointer to the current HEAD is safe.
git -C "$CLONE" checkout -B main

# --- Shared exclude list (applies to every transfer) ---
EXCLUDES=(
    --exclude ".planning"
    --exclude ".claude"
    --exclude "CLAUDE.md"
    --exclude ".env.release"
    --exclude "build"
    --exclude "xcuserdata"
    --exclude "*.xcuserdata*"
    --exclude "*.profraw"
    --exclude ".DS_Store"
    --exclude ".git"
    --exclude ".sparkle-tools"
)

# --- Sync directories (allowlist, --delete inside each synced dir only) ---
echo "==> Syncing macssential/ ..."
rsync -a --delete "${EXCLUDES[@]}" macssential/ "$CLONE/macssential/"

echo "==> Syncing scripts/ ..."
rsync -a --delete "${EXCLUDES[@]}" scripts/ "$CLONE/scripts/"

echo "==> Syncing packaging/ (minus releases-repo) ..."
rsync -a --delete "${EXCLUDES[@]}" --exclude "releases-repo" \
    packaging/ "$CLONE/packaging/"

echo "==> Syncing docs/ ..."
rsync -a --delete "${EXCLUDES[@]}" docs/ "$CLONE/docs/"

echo "==> Syncing .github/ ..."
rsync -a --delete "${EXCLUDES[@]}" .github/ "$CLONE/.github/"

# --- Sync top-level files (no --delete at clone root: preserves public-repo
#     -only files such as a future .nojekyll) ---
echo "==> Syncing top-level files ..."
rsync -a "${EXCLUDES[@]}" LICENSE .gitignore .env.release.example "$CLONE/"

# --- Public front-page READMEs: releases-repo READMEs go to the clone root.
#     The dev repo's own root README.md is intentionally NOT synced. ---
echo "==> Placing public READMEs at repo root ..."
for readme in README.md README.ko.md README.ja.md README.zh-Hans.md; do
    cp "packaging/releases-repo/$readme" "$CLONE/$readme"
done

# --- Commit + push (idempotent: skip when nothing changed) ---
git -C "$CLONE" add -A
if git -C "$CLONE" diff --cached --quiet; then
    echo "No changes to sync"
    exit 0
fi

git -C "$CLONE" commit -m "Sync source from development repo"
git -C "$CLONE" push -u origin main

# --- Summary (public values only) ---
FILE_COUNT=$(git -C "$CLONE" ls-files | wc -l | tr -d ' ')
COMMIT_HASH=$(git -C "$CLONE" rev-parse --short HEAD)
echo ""
echo "==> Sync complete"
echo "    Target repo: $PUBLIC_REPO"
echo "    Files:       $FILE_COUNT tracked"
echo "    Commit:      $COMMIT_HASH"
