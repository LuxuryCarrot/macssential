#!/bin/bash
set -euo pipefail

# =============================================================================
# stats.sh -- macssential distribution metrics snapshot
#
# Usage:
#   bash scripts/stats.sh
#
# Prints current metrics (release downloads, repo traffic, stars, tap clones)
# and appends a snapshot row to .stats-history.csv (gitignored) so trends
# survive GitHub's 14-day traffic retention window.
#
# Requires an authenticated gh CLI. Traffic endpoints need push access.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

APP_REPO="LuxuryCarrot/macssential"
TAP_REPO="LuxuryCarrot/homebrew-tap"
HISTORY_FILE=".stats-history.csv"

if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh CLI is not authenticated (run 'gh auth login')." >&2
    exit 1
fi

# --- Collect ---
RELEASES_JSON=$(gh api "repos/$APP_REPO/releases" 2>/dev/null || echo "[]")
TOTAL_DOWNLOADS=$(echo "$RELEASES_JSON" | /usr/bin/python3 -c '
import json, sys
rels = json.load(sys.stdin)
print(sum(a.get("download_count", 0) for r in rels for a in r.get("assets", [])))
')

VIEWS_JSON=$(gh api "repos/$APP_REPO/traffic/views" 2>/dev/null || echo '{"count":0,"uniques":0}')
CLONES_JSON=$(gh api "repos/$APP_REPO/traffic/clones" 2>/dev/null || echo '{"count":0,"uniques":0}')
TAP_CLONES_JSON=$(gh api "repos/$TAP_REPO/traffic/clones" 2>/dev/null || echo '{"count":0,"uniques":0}')

VIEWS=$(echo "$VIEWS_JSON" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"])')
VIEWS_UNIQ=$(echo "$VIEWS_JSON" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["uniques"])')
CLONES=$(echo "$CLONES_JSON" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"])')
CLONES_UNIQ=$(echo "$CLONES_JSON" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["uniques"])')
TAP_CLONES=$(echo "$TAP_CLONES_JSON" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"])')
TAP_CLONES_UNIQ=$(echo "$TAP_CLONES_JSON" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["uniques"])')
STARS=$(gh api "repos/$APP_REPO" --jq '.stargazers_count')
WATCHERS=$(gh api "repos/$APP_REPO" --jq '.subscribers_count')
FORKS=$(gh api "repos/$APP_REPO" --jq '.forks_count')
OPEN_ISSUES=$(gh api "repos/$APP_REPO" --jq '.open_issues_count')

# --- Display ---
echo "macssential distribution metrics  ($(date '+%Y-%m-%d %H:%M'))"
echo "────────────────────────────────────────────────────"
echo "DMG downloads (all releases, cumulative):  $TOTAL_DOWNLOADS"
echo "$RELEASES_JSON" | /usr/bin/python3 -c '
import json, sys
for r in json.load(sys.stdin):
    tag = r["tag_name"]
    for a in r.get("assets", []):
        print("    {:<10} {:>5}  ({})".format(tag, a["download_count"], a["name"]))
'
echo "Repo views (14d):        $VIEWS total / $VIEWS_UNIQ unique"
echo "Repo clones (14d):       $CLONES total / $CLONES_UNIQ unique  (bots + sync included)"
echo "brew tap clones (14d):   $TAP_CLONES total / $TAP_CLONES_UNIQ unique  (~= new taps)"
echo "Stars: $STARS   Watchers: $WATCHERS   Forks: $FORKS   Open issues: $OPEN_ISSUES"
echo "────────────────────────────────────────────────────"

# --- Append history snapshot ---
if [ ! -f "$HISTORY_FILE" ]; then
    echo "date,total_downloads,views_14d,views_uniq_14d,clones_14d,clones_uniq_14d,tap_clones_14d,tap_clones_uniq_14d,stars,watchers,forks,open_issues" > "$HISTORY_FILE"
fi
echo "$(date '+%Y-%m-%d'),$TOTAL_DOWNLOADS,$VIEWS,$VIEWS_UNIQ,$CLONES,$CLONES_UNIQ,$TAP_CLONES,$TAP_CLONES_UNIQ,$STARS,$WATCHERS,$FORKS,$OPEN_ISSUES" >> "$HISTORY_FILE"
echo "Snapshot appended to $HISTORY_FILE ($(( $(wc -l < "$HISTORY_FILE") - 1 )) rows)"
