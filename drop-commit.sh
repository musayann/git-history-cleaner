#!/usr/bin/env bash
#
# drop-commit.sh
#
# Surgically remove ONE bad commit from the middle of a branch's history while
# keeping the good commits on top of it, then force-push the rewritten branch.
# Use this when the bad commit is NOT the branch tip (if it IS the tip,
# restore-branch.sh is simpler).
#
#     P -- B(bad) -- C -- D        becomes        P -- C' -- D'
#
# Safety: the whole rewrite happens inside git's object database. We clone with
# --bare --no-checkout (no working tree is ever written, and clone never runs
# the repo's hooks), then replay the good commits with `git merge-tree
# --write-tree` + `git commit-tree`. The malicious files pass through the object
# store as INERT blobs -- they are never written to disk as files and never
# executed. The temp dir is deleted on exit. This is why it needs git >= 2.38.
#
# Auth is delegated to gh's git credential helper, so the token never appears in
# the command line, the remote URL, or shell history.
#
# Usage:
#   ./drop-commit.sh <owner/repo> <branch> <bad-sha> [-y|--yes]
#
# Example:
#   ./drop-commit.sh Brainix-Devs/lesson-service dev a92ebcc49df32b373a31c035b2538a2fed3604b1
#
# Options:
#   -y, --yes    Skip the confirmation prompt (use with care)
#   -h, --help   Show this help

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: drop-commit.sh <owner/repo> <branch> <bad-sha> [-y|--yes]

Arguments:
  owner/repo   Repository in OWNER/REPO form (e.g. Brainix-Devs/lesson-service)
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
gh auth status >/dev/null 2>&1 || { echo "Error: not authenticated. Run 'gh auth login' (token needs Contents write)." >&2; exit 1; }

# `git merge-tree --write-tree --merge-base` needs git >= 2.38.
GIT_VER="$(git version | awk '{print $3}')"
GIT_MAJOR="${GIT_VER%%.*}"
GIT_REST="${GIT_VER#*.}"
GIT_MINOR="${GIT_REST%%.*}"
if [ "$GIT_MAJOR" -lt 2 ] || { [ "$GIT_MAJOR" -eq 2 ] && [ "$GIT_MINOR" -lt 38 ]; }; then
  echo "Error: need git >= 2.38 for in-object-store rebase (have ${GIT_VER})." >&2
  exit 1
fi

# Delegate auth to gh so the token is never exposed.
GIT_AUTH=(-c credential.helper= -c "credential.helper=!gh auth git-credential")

# --- bare, no-checkout clone into a temp dir; always clean up ---
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

GD="$WORKDIR/repo.git"   # bare repo == git dir

echo "Fetching objects for ${REPO} (branch: ${BRANCH}), no working tree ..."
git "${GIT_AUTH[@]}" clone --quiet --bare --single-branch --branch "$BRANCH" \
    "https://github.com/${REPO}.git" "$GD" \
  || { echo "Error: clone failed. Check repo/branch names and access." >&2; exit 1; }

# All later git commands operate on the bare object DB -- never a working tree.
git() { command git --git-dir="$GD" "$@"; }

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

bad_parents="$(git rev-list --no-walk --parents "$BAD_FULL" | wc -w)"   # 1 (self) + parents
if [ "$bad_parents" -gt 2 ]; then
  echo "Error: ${BAD_FULL} is a merge commit; refusing to drop it automatically." >&2
  echo "       Handle merge commits manually with an interactive rebase." >&2
  exit 1
fi
if [ "$bad_parents" -lt 2 ]; then
  echo "Error: ${BAD_FULL} is the root commit; it has no parent to rebase onto." >&2
  exit 1
fi

PARENT="$(git rev-parse "${BAD_FULL}^")"
CURRENT_SHA="$(git rev-parse "$REF")"
BAD_SUBJECT="$(git log -1 --format='%s' "$BAD_FULL")"

# Commits to replay, oldest-first: everything on the branch after the bad commit.
mapfile -t REPLAY < <(git rev-list --reverse --topo-order "${BAD_FULL}..${REF}")

# Refuse merge commits inside the replay range (merge-tree replay is non-trivial).
for c in "${REPLAY[@]}"; do
  pc="$(git rev-list --no-walk --parents "$c" | wc -w)"
  if [ "$pc" -gt 2 ]; then
    echo "Error: ${c} (on top of the bad commit) is a merge commit; refusing." >&2
    echo "       Rewriting across merges needs a manual interactive rebase." >&2
    exit 1
  fi
done

echo
echo "About to rewrite history (in object store only, no checkout):"
echo "  Repo:      ${REPO}"
echo "  Branch:    ${BRANCH}"
echo "  Drop:      ${BAD_FULL}  (\"${BAD_SUBJECT}\")"
echo "  Onto:      ${PARENT}  (its parent)"
echo "  Replaying: ${#REPLAY[@]} commit(s) on top of it (they get NEW SHAs)"
echo "  Tip now:   ${CURRENT_SHA}"
echo
echo "This force-pushes '${BRANCH}'. Anyone with the old branch must reset/re-clone."
echo "Note: any GPG signatures on the rewritten commits are dropped."
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

# --- replay each good commit onto the new base, entirely in the object DB ---
NEWBASE="$PARENT"
for c in "${REPLAY[@]}"; do
  cparent="$(git rev-parse "${c}^")"

  # Three-way merge in the object store: base=parent(c), ours=NEWBASE, theirs=c.
  # Result tree = NEWBASE + (c's changes). No working tree is touched.
  if ! tree="$(git merge-tree --write-tree --merge-base="$cparent" "$NEWBASE" "$c" 2>/dev/null)"; then
    echo >&2
    echo "Error: conflict re-applying ${c} after dropping the bad commit." >&2
    echo "       A later commit depends on changes from the dropped commit, so the" >&2
    echo "       rewrite can't be done automatically. Conflicting paths:" >&2
    git merge-tree --write-tree --name-only --merge-base="$cparent" "$NEWBASE" "$c" 2>/dev/null \
      | tail -n +2 | sed 's/^/         - /' >&2 || true
    exit 1
  fi
  tree="$(printf '%s' "$tree" | head -n1)"

  # Recreate the commit on the new base, preserving author/committer identity+dates.
  an="$(git log -1 --format=%an "$c")"; ae="$(git log -1 --format=%ae "$c")"; ad="$(git log -1 --format=%aI "$c")"
  cn="$(git log -1 --format=%cn "$c")"; ce="$(git log -1 --format=%ce "$c")"; cdate="$(git log -1 --format=%cI "$c")"
  NEWBASE="$(git log -1 --format=%B "$c" | \
    GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
    GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" GIT_COMMITTER_DATE="$cdate" \
    git commit-tree "$tree" -p "$NEWBASE")"
done

NEW_SHA="$NEWBASE"

# --- force-push the rewritten branch ---
# --force-with-lease with an explicit expected value guards against clobbering a
# push that landed after our clone (bare clones have no remote-tracking refs).
echo "Force-pushing rewritten '${BRANCH}' ..."
if ! git "${GIT_AUTH[@]}" push --force-with-lease="${REF}:${CURRENT_SHA}" \
       origin "${NEW_SHA}:${REF}" >/dev/null 2>&1; then
  echo "Error: push failed. Either '${BRANCH}' is protected against force-pushes" >&2
  echo "       (temporarily relax the rule), or someone pushed after our clone" >&2
  echo "       (re-run to pick up their changes)." >&2
  exit 1
fi

echo
echo "Done. '${BRANCH}' rewritten: ${CURRENT_SHA} -> ${NEW_SHA}"
echo "Dropped commit ${BAD_FULL} and replayed ${#REPLAY[@]} commit(s) on top of it."
echo "No working tree was ever created; the malicious files were never checked out."
