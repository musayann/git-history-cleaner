#!/usr/bin/env bash
#
# detect-force-push.sh
#
# Scan a GitHub repo's recent push events for force-pushes that rewrote history
# (i.e. dropped commits), and flag the BAD hash (the force-pushed head) and the
# GOOD hash (the pre-push state you'd restore to).
#
# How it decides: for each push it compares the "before" and "head" SHAs via the
# GitHub compare API. A normal push is a fast-forward (before is an ancestor of
# head, nothing dropped). If the compare shows commits reachable from "before"
# that are missing from "head" (behind_by > 0), the push discarded history and
# is flagged as a likely force-push.
#
# Usage:
#   ./detect-force-push.sh <owner/repo> [branch]
#
# Examples:
#   ./detect-force-push.sh acme-corp/widget-service
#   ./detect-force-push.sh acme-corp/widget-service dev
#
# Note: the Events API only covers roughly the last 90 days and up to 300 events,
# so this sees recent activity only. For older history use the org audit log.

set -euo pipefail

REPO="${1:-}"
BRANCH="${2:-}"
ZERO="0000000000000000000000000000000000000000"

if [ -z "$REPO" ]; then
  echo "Usage: $0 <owner/repo> [branch]" >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI not found. See https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: not authenticated. Run 'gh auth login'." >&2; exit 1; }

# Optional branch filter for the jq selection.
if [ -n "$BRANCH" ]; then
  REF_FILTER="and .payload.ref==\"refs/heads/${BRANCH}\""
else
  REF_FILTER=""
fi

echo "Scanning push events for ${REPO}${BRANCH:+ (branch: ${BRANCH})} ..."
echo "(window: last ~90 days, up to 300 events)"
echo

PUSHES=$(gh api --paginate "repos/${REPO}/events?per_page=100" \
  --jq ".[] | select(.type==\"PushEvent\" ${REF_FILTER}) | [.created_at, .payload.ref, .payload.before, .payload.head, .actor.login] | @tsv" \
  || { echo "Error: could not read events. Check repo name and access." >&2; exit 1; })

if [ -z "$PUSHES" ]; then
  echo "No push events found in the available window."
  exit 0
fi

FLAGGED=0

while IFS=$'\t' read -r ts ref before head actor; do
  [ -z "$ts" ] && continue
  # Skip branch-creation pushes (before is all zeros).
  [ "$before" = "$ZERO" ] && continue

  # Compare before...head. behind_by = commits on "before" missing from "head".
  resp=$(gh api "repos/${REPO}/compare/${before}...${head}" \
           --jq '{status: .status, ahead: (.ahead_by // 0), behind: (.behind_by // 0)}' 2>/dev/null || echo "")

  if [ -z "$resp" ]; then
    echo "?  ${ts}  ${ref#refs/heads/}  could not compare (old hash may already be collected)"
    echo "     before=${before}  head=${head}"
    echo
    continue
  fi

  status=$(echo "$resp" | jq -r '.status')
  behind=$(echo "$resp" | jq -r '.behind // 0')
  ahead=$(echo "$resp" | jq -r '.ahead // 0')
  case "$behind" in ''|*[!0-9]*) behind=0 ;; esac

  if [ "$behind" -gt 0 ]; then
    FLAGGED=$((FLAGGED + 1))
    echo "FLAG: likely force-push on '${ref#refs/heads/}'  at ${ts}  by ${actor}"
    echo "    dropped ${behind} commit(s), added ${ahead}  (compare status: ${status})"
    echo "    BAD  hash (force-pushed head):  ${head}"
    echo "    GOOD hash (restore candidate):  ${before}"
    echo
  fi
done <<< "$PUSHES"

echo "-----"
if [ "$FLAGGED" -eq 0 ]; then
  echo "No force-pushes (history rewrites) detected in the available window."
else
  echo "Flagged ${FLAGGED} likely force-push event(s)."
  echo "Verify a GOOD hash still resolves before restoring:"
  echo "  gh api repos/${REPO}/commits/<GOOD_hash> --jq '{date: .commit.author.date, msg: .commit.message}'"
  echo "Then restore, e.g.:"
  echo "  ./restore-branch.sh ${REPO} <branch> <GOOD_hash>"
fi