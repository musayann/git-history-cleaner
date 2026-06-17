#!/usr/bin/env bash
#
# replace-commit.sh
#
# Replace ONE bad commit in a branch's history with a different, corrected
# commit (GOOD), then replay every commit after the bad one on top of GOOD and
# force-push. This is exactly:
#
#     git rebase --onto <good-sha> <bad-sha> <branch>
#
#     X -- GOOD (corrected, lives elsewhere)        X -- GOOD -- C' -- D'
#     ... -- P -- B(bad) -- C -- D       becomes
#
# B's old parent P is discarded; GOOD takes its place. C/D are replayed (new
# SHAs), so their content is recomputed against GOOD -- which removes B's
# malicious file changes for any path the later commits don't re-touch.
#
# Use this when GOOD is a SEPARATE replacement commit. If you only want to drop
# the bad commit (GOOD == its parent), use drop-commit.sh instead.
#
# Safety: the whole rewrite happens inside git's object database. We clone
# --bare (no working tree is ever written, and clone never runs the repo's
# hooks), then replay with `git merge-tree --write-tree` + `git commit-tree`.
# The malicious files stay INERT blobs -- never written to disk as files, never
# executed. The temp dir is deleted on exit. Needs git >= 2.38.
#
# Auth is delegated to gh's git credential helper, so the token never appears in
# the command line, the remote URL, or shell history.
#
# Usage:
#   ./replace-commit.sh <owner/repo> <branch> <bad-sha> <good-sha> [--dry-run] [-y|--yes]
#
# Example:
#   ./replace-commit.sh acme-corp/widget-service master \
#       1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b \
#       0f1e2d3c4b5a69788990a1b2c3d4e5f607182930
#
# Options:
#   --dry-run    Do everything except the push; print old->new tip and a diffstat
#   -y, --yes    Skip the confirmation prompt (use with care)
#   -h, --help   Show this help

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: replace-commit.sh <owner/repo> <branch> <bad-sha> <good-sha> [--dry-run] [-y|--yes]

Arguments:
  owner/repo   Repository in OWNER/REPO form (e.g. acme-corp/widget-service)
  branch       Branch to rewrite (e.g. master)
  bad-sha      The commit to remove from history (full or abbreviated SHA)
  good-sha     The replacement commit GOOD becomes the new base in BAD's place

Options:
  --dry-run    Compute the rewrite and print old->new tip + diffstat; no push
  -y, --yes    Skip the confirmation prompt
  -h, --help   Show this help
EOF
}

# --- parse arguments ---
ASSUME_YES=0
DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "Unknown option: $arg" >&2; usage; exit 1 ;;
    *)         POSITIONAL+=("$arg") ;;
  esac
done

if [ "${#POSITIONAL[@]}" -ne 4 ]; then
  echo "Error: expected 4 arguments, got ${#POSITIONAL[@]}." >&2
  usage
  exit 1
fi

REPO="${POSITIONAL[0]}"
BRANCH="${POSITIONAL[1]}"
BAD_SHA="${POSITIONAL[2]}"
GOOD_SHA="${POSITIONAL[3]}"

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

# --- bare clone into a temp dir; always clean up ---
# Full clone (NOT --single-branch): GOOD lives on another branch, so we need
# every ref's objects in the local object DB. Bare == no working tree.
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

GD="$WORKDIR/repo.git"

echo "Fetching objects for ${REPO}, no working tree ..."
git "${GIT_AUTH[@]}" clone --quiet --bare \
    "https://github.com/${REPO}.git" "$GD" \
  || { echo "Error: clone failed. Check repo name and access." >&2; exit 1; }

git() { command git --git-dir="$GD" "$@"; }   # all ops on the bare object DB
REF="refs/heads/${BRANCH}"

# --- resolve and validate ---
git rev-parse --verify --quiet "$REF" >/dev/null \
  || { echo "Error: branch '${BRANCH}' not found in ${REPO}." >&2; exit 1; }

BAD_FULL="$(git rev-parse --verify --quiet "${BAD_SHA}^{commit}" || true)"
if [ -z "$BAD_FULL" ]; then
  echo "Error: bad commit '${BAD_SHA}' is not a commit in this repo." >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$BAD_FULL" "$REF"; then
  echo "Error: ${BAD_FULL} is not in the history of '${BRANCH}'." >&2
  exit 1
fi

GOOD_FULL="$(git rev-parse --verify --quiet "${GOOD_SHA}^{commit}" || true)"
if [ -z "$GOOD_FULL" ]; then
  echo "Error: good commit '${GOOD_SHA}' is not reachable in ${REPO}." >&2
  echo "       GOOD must be pushed to the remote (on any branch/tag) first." >&2
  exit 1
fi

# BAD must have exactly one parent (need a single anchor for the first replay).
bad_parents="$(git rev-list --no-walk --parents "$BAD_FULL" | wc -w)"   # 1 (self) + parents
if [ "$bad_parents" -gt 2 ]; then
  echo "Error: ${BAD_FULL} is a merge commit; replaying across merges is unsupported here." >&2
  echo "       See the merges fallback in the script header." >&2
  exit 1
fi
if [ "$bad_parents" -lt 2 ]; then
  echo "Error: ${BAD_FULL} is the root commit; it has no parent to anchor the replay." >&2
  exit 1
fi

CURRENT_SHA="$(git rev-parse "$REF")"
BAD_SUBJECT="$(git log -1 --format='%s' "$BAD_FULL")"
GOOD_SUBJECT="$(git log -1 --format='%s' "$GOOD_FULL")"

# Commits to replay, oldest-first: everything on the branch after the bad commit.
# (read loop instead of mapfile: macOS ships bash 3.2, which has no mapfile.)
REPLAY=()
while IFS= read -r _line; do REPLAY+=("$_line"); done \
  < <(git rev-list --reverse --topo-order "${BAD_FULL}..${REF}")

# --- topology gate: merges in the range can't be replayed reliably ---
for c in ${REPLAY[@]+"${REPLAY[@]}"}; do
  pc="$(git rev-list --no-walk --parents "$c" | wc -w)"
  if [ "$pc" -gt 2 ]; then
    echo "Error: ${c} (on top of the bad commit) is a merge commit." >&2
    echo "       merge-tree can't replay merges reliably, so this script stops." >&2
    echo >&2
    echo "Pick a merge-safe fallback:" >&2
    echo "  (a) If the malware is specific files, strip them from ALL history:" >&2
    echo "        git filter-repo --invert-paths --path <bad-file> [--path ...]" >&2
    echo "      (merge topology preserved, no checkout)." >&2
    echo "  (b) True --onto across merges, in a throwaway container (no host checkout):" >&2
    echo "        git rebase --onto ${GOOD_FULL} ${BAD_FULL} --rebase-merges ${BRANCH}" >&2
    exit 1
  fi
done

echo
echo "About to rewrite history (object store only, no checkout):"
echo "  Repo:      ${REPO}"
echo "  Branch:    ${BRANCH}"
echo "  Drop:      ${BAD_FULL}  (\"${BAD_SUBJECT}\")"
echo "  Onto GOOD: ${GOOD_FULL}  (\"${GOOD_SUBJECT}\")"
echo "  Replaying: ${#REPLAY[@]} commit(s) on top of it (they get NEW SHAs)"
echo "  Tip now:   ${CURRENT_SHA}"
echo
if [ "$DRY_RUN" -ne 1 ]; then
  echo "This force-pushes '${BRANCH}'. Anyone with the old branch must reset/re-clone."
  echo "Note: any GPG signatures on the replayed commits are dropped."
  echo
fi

# --- confirm (skipped for dry-run) ---
if [ "$DRY_RUN" -ne 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
  printf "Type 'yes' to proceed: "
  read -r REPLY
  if [ "$REPLY" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

# --- replay each commit after BAD onto GOOD, entirely in the object DB ---
# For each commit c, three-way merge: base=parent(c), ours=NEWBASE, theirs=c.
# The first commit's parent is BAD, so it computes (c - BAD) and applies it onto
# GOOD -- exactly `git rebase --onto GOOD BAD`. No working tree is touched.
NEWBASE="$GOOD_FULL"
for c in ${REPLAY[@]+"${REPLAY[@]}"}; do
  cparent="$(git rev-parse "${c}^")"

  if ! tree="$(git merge-tree --write-tree --merge-base="$cparent" "$NEWBASE" "$c" 2>/dev/null)"; then
    echo >&2
    echo "Error: conflict re-applying ${c} onto the new base." >&2
    echo "       A later commit depends on changes from the dropped commit, so the" >&2
    echo "       rewrite can't be done automatically. Conflicting paths:" >&2
    git merge-tree --write-tree --name-only --merge-base="$cparent" "$NEWBASE" "$c" 2>/dev/null \
      | tail -n +2 | sed 's/^/         - /' >&2 || true
    exit 1
  fi
  tree="$(printf '%s' "$tree" | head -n1)"

  an="$(git log -1 --format=%an "$c")"; ae="$(git log -1 --format=%ae "$c")"; ad="$(git log -1 --format=%aI "$c")"
  cn="$(git log -1 --format=%cn "$c")"; ce="$(git log -1 --format=%ce "$c")"; cdate="$(git log -1 --format=%cI "$c")"
  NEWBASE="$(git log -1 --format=%B "$c" | \
    GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
    GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" GIT_COMMITTER_DATE="$cdate" \
    git commit-tree "$tree" -p "$NEWBASE")"
done

NEW_SHA="$NEWBASE"

# --- dry-run: report and stop before pushing ---
if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] '${BRANCH}' would change: ${CURRENT_SHA} -> ${NEW_SHA}"
  echo "[dry-run] diffstat (old tip -> rewritten tip):"
  git diff --stat "$CURRENT_SHA" "$NEW_SHA" | sed 's/^/    /' || true
  echo "[dry-run] No push performed. Re-run without --dry-run to apply."
  exit 0
fi

# --- force-push the rewritten branch ---
# --force-with-lease with the captured old tip guards against clobbering a push
# that landed after our clone (bare clones have no remote-tracking refs).
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
echo "Replaced ${BAD_FULL} with ${GOOD_FULL} and replayed ${#REPLAY[@]} commit(s) on top."
echo "No working tree was ever created; the malicious files were never checked out."
