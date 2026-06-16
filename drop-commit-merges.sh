#!/usr/bin/env bash
#
# drop-commit-merges.sh
#
# Remove ONE bad commit from a branch's history and keep everything on top of
# it, EVEN WHEN there are merge commits between the bad commit and the tip.
# Then force-push the rewritten branch. (For purely linear history, drop-commit.sh
# is lighter and needs no extra tooling; use this one when that script reports
# "rewriting across merges requires a manual interactive rebase".)
#
#     P -- B(bad) -- C --.            P -- C' --.
#                 \       \    =>            \    \
#                  X ----- M(merge) -- D      X -- M' -- D'
#
# Engine: git filter-repo. It rewrites history by STREAMING objects
# (fast-export -> filter -> fast-import), so it correctly drops the bad commit
# and reparents its children while preserving the merge topology.
#
# Safety (same guarantees as drop-commit.sh): we clone --bare --no-checkout, so
# no working tree is ever written and the repo's hooks never run. filter-repo
# operates only on the object store -- the malicious files stay INERT blobs and
# are never written to disk as files or executed. The temp dir is deleted on exit.
#
# Dropping a commit drops exactly that commit's file changes: children that also
# touched those files keep their own versions; files only the bad commit added
# simply disappear.
#
# Requires: gh, git >= 2.24, and git-filter-repo (`brew install git-filter-repo`
# or `pip install git-filter-repo`). Auth is delegated to gh's credential helper.
#
# Usage:
#   ./drop-commit-merges.sh <owner/repo> <branch> <bad-sha> [-y|--yes]
#
# Options:
#   -y, --yes    Skip the confirmation prompt
#   -h, --help   Show this help

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: drop-commit-merges.sh <owner/repo> <branch> <bad-sha> [-y|--yes]

Arguments:
  owner/repo   Repository in OWNER/REPO form
  branch       Branch to rewrite (e.g. dev)
  bad-sha      The commit to remove from history (full or abbreviated SHA)

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
BAD_SHA="${POSITIONAL[2]}"

# --- preflight checks ---
command -v gh  >/dev/null 2>&1 || { echo "Error: gh CLI not found. Install from https://cli.github.com" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Error: git not found." >&2; exit 1; }
if ! git filter-repo --version >/dev/null 2>&1 && ! command -v git-filter-repo >/dev/null 2>&1; then
  echo "Error: git-filter-repo not found. Install with:" >&2
  echo "       brew install git-filter-repo   (or)   pip install git-filter-repo" >&2
  exit 1
fi
gh auth status >/dev/null 2>&1 || { echo "Error: not authenticated. Run 'gh auth login' (token needs Contents write)." >&2; exit 1; }

# Delegate auth to gh so the token is never exposed.
GIT_AUTH=(-c credential.helper= -c "credential.helper=!gh auth git-credential")

# --- bare, no-checkout clone into a temp dir; always clean up ---
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

GD="$WORKDIR/repo.git"

echo "Fetching objects for ${REPO} (branch: ${BRANCH}), no working tree ..."
git "${GIT_AUTH[@]}" clone --quiet --bare --single-branch --branch "$BRANCH" \
    "https://github.com/${REPO}.git" "$GD" \
  || { echo "Error: clone failed. Check repo/branch names and access." >&2; exit 1; }

git() { command git --git-dir="$GD" "$@"; }   # all ops on the bare object DB
REF="refs/heads/${BRANCH}"

# --- resolve and validate the bad commit ---
BAD_FULL="$(git rev-parse --verify --quiet "${BAD_SHA}^{commit}" || true)"
if [ -z "$BAD_FULL" ]; then
  echo "Error: '${BAD_SHA}' is not a commit in this repo." >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$BAD_FULL" "$REF"; then
  echo "Error: ${BAD_FULL} is not in the history of '${BRANCH}'." >&2
  exit 1
fi

CURRENT_SHA="$(git rev-parse "$REF")"
BAD_SUBJECT="$(git log -1 --format='%s' "$BAD_FULL")"
bad_parents="$(git rev-list --no-walk --parents "$BAD_FULL" | wc -w)"
IS_MERGE=0; [ "$bad_parents" -gt 2 ] && IS_MERGE=1

echo
echo "About to rewrite history (object store only, no checkout):"
echo "  Repo:    ${REPO}"
echo "  Branch:  ${BRANCH}"
echo "  Drop:    ${BAD_FULL}  (\"${BAD_SUBJECT}\")"
echo "  Tip now: ${CURRENT_SHA}"
if [ "$IS_MERGE" -eq 1 ]; then
  echo "  WARNING: the bad commit is itself a MERGE commit; its children will be"
  echo "           reparented onto its parents. Review the result before relying on it."
fi
echo
echo "All commits after the bad one (including any merges) get NEW SHAs."
echo "This force-pushes '${BRANCH}'. Anyone with the old branch must reset/re-clone."
echo "Note: any GPG signatures on rewritten commits are dropped."
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

# --- rewrite: drop the bad commit, preserving topology ---
# filter-repo streams objects; no working tree, no hook/code execution.
echo "Rewriting history with git filter-repo ..."
git filter-repo --force --partial --refs "$REF" --commit-callback "
if commit.original_id == b'${BAD_FULL}':
    commit.skip()
" >/dev/null 2>&1 || { echo "Error: filter-repo rewrite failed." >&2; exit 1; }

NEW_SHA="$(git rev-parse "$REF")"
if [ "$NEW_SHA" = "$CURRENT_SHA" ]; then
  echo "Error: history unchanged (bad commit not found in the stream?)." >&2
  exit 1
fi

# --- force-push the rewritten branch ---
# Push by explicit URL (robust whether or not filter-repo kept the remote).
# --force-with-lease with the captured old tip guards against a racing push.
echo "Force-pushing rewritten '${BRANCH}' ..."
if ! git "${GIT_AUTH[@]}" push --force-with-lease="${REF}:${CURRENT_SHA}" \
       "https://github.com/${REPO}.git" "${NEW_SHA}:${REF}" >/dev/null 2>&1; then
  echo "Error: push failed. Either '${BRANCH}' is protected against force-pushes" >&2
  echo "       (temporarily relax the rule), or someone pushed after our clone" >&2
  echo "       (re-run to pick up their changes)." >&2
  exit 1
fi

echo
echo "Done. '${BRANCH}' rewritten: ${CURRENT_SHA} -> ${NEW_SHA}"
echo "Dropped commit ${BAD_FULL}; merge topology preserved."
echo "No working tree was ever created; the malicious files were never checked out."
