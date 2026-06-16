#!/usr/bin/env bash
#
# restore-branch.sh
#
# Force-restore a GitHub branch to a known-good commit, e.g. to undo a
# malicious force-push (PolinRider-style). Uses the GitHub CLI (gh) so the
# token is handled by gh and never appears in the command or shell history.
#
# Usage:
#   ./restore-branch.sh <owner/repo> <branch> <good-sha> [-y|--yes]
#
# Example:
#   ./restore-branch.sh Brainix-Devs/lesson-service dev a92ebcc49df32b373a31c035b2538a2fed3604b1
#
# Options:
#   -y, --yes    Skip the confirmation prompt (use with care)
#   -h, --help   Show this help

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: restore-branch.sh <owner/repo> <branch> <good-sha> [-y|--yes]

Arguments:
  owner/repo   Repository in OWNER/REPO form (e.g. Brainix-Devs/lesson-service)
  branch       Branch to restore (e.g. dev)
  good-sha     The commit SHA to reset the branch to (the known-good state)

Options:
  -y, --yes    Skip the confirmation prompt
  -h, --help   Show this help
EOF
}

# --- parse arguments ---
ASSUME_YES=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "Unknown option: $arg" >&2; usage; exit 1 ;;
    *)         POSITIONAL+=("$arg") ;;
  esac
done

if [ "${#POSITIONAL[@]}" -ne 3 ]; then
  echo "Error: expected 3 arguments, got ${#POSITIONAL[@]}." >&2
  usage
  exit 1
fi

REPO="${POSITIONAL[0]}"
BRANCH="${POSITIONAL[1]}"
GOOD_SHA="${POSITIONAL[2]}"

# --- preflight checks ---
command -v gh >/dev/null 2>&1 \
  || { echo "Error: gh CLI not found. Install from https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 \
  || { echo "Error: not authenticated. Run 'gh auth login' (token needs Contents write)." >&2; exit 1; }

# --- read current head ---
echo "Reading current head of ${REPO}@${BRANCH} ..."
CURRENT_SHA=$(gh api "repos/${REPO}/git/refs/heads/${BRANCH}" --jq '.object.sha') \
  || { echo "Error: could not read branch '${BRANCH}'. Check repo/branch names and access." >&2; exit 1; }

if [ "$CURRENT_SHA" = "$GOOD_SHA" ]; then
  echo "Branch '${BRANCH}' already points at ${GOOD_SHA}. Nothing to do."
  exit 0
fi

# --- how many commits will be dropped (best effort) ---
AHEAD=$(gh api "repos/${REPO}/compare/${GOOD_SHA}...${CURRENT_SHA}" --jq '.ahead_by' 2>/dev/null || echo "?")

echo
echo "About to force-restore:"
echo "  Repo:     ${REPO}"
echo "  Branch:   ${BRANCH}"
echo "  From:     ${CURRENT_SHA}  (current head)"
echo "  To:       ${GOOD_SHA}  (good commit)"
echo "  Dropping: ${AHEAD} commit(s) currently on top of the good commit"
echo

# --- confirm ---
if [ "$ASSUME_YES" -ne 1 ]; then
  printf "Type 'yes' to proceed: "
  read -r REPLY
  if [ "$REPLY" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

# --- force-update the branch ---
echo "Resetting '${BRANCH}' to ${GOOD_SHA} ..."
if ! gh api --method PATCH "repos/${REPO}/git/refs/heads/${BRANCH}" \
       -f sha="${GOOD_SHA}" \
       -F force=true >/dev/null; then
  echo "Error: reset failed. If '${BRANCH}' is protected against force-pushes," >&2
  echo "       temporarily relax that rule and retry." >&2
  exit 1
fi

# --- verify ---
NEW_SHA=$(gh api "repos/${REPO}/git/refs/heads/${BRANCH}" --jq '.object.sha')
if [ "$NEW_SHA" = "$GOOD_SHA" ]; then
  echo "Done. '${BRANCH}' now points at ${NEW_SHA}."
else
  echo "Something is off: '${BRANCH}' is at ${NEW_SHA}, expected ${GOOD_SHA}." >&2
  exit 1
fi