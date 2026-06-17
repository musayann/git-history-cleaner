# git-history-cleaner

Safely **drop**, **replace**, or **restore** commits on a remote GitHub branch — without
ever checking out the code.

A toolkit of small, standalone bash scripts for rewriting remote branch history. Every
rewrite happens entirely inside git's object database, so you can clean up a branch even
when its history contains files you don't want to (or shouldn't) execute. One real-world
use is recovering a repo after a malicious force-push.

## Why it's safe

- **No working tree.** Each script clones the repo `--bare --no-checkout` into a temp dir,
  so files pass through git as inert blobs — they're never written to disk as files and
  never executed, and the repo's hooks never run.
- **Object-store-only rewrites.** History is replayed with `git merge-tree --write-tree` +
  `git commit-tree` (or `git filter-repo`), all in the bare object DB.
- **Temp dir is deleted on exit**, even on failure.
- **Token never exposed.** Auth is delegated to `gh`'s git credential helper, so your
  token never appears in command-line arguments, the remote URL, or shell history.
- **Guarded pushes.** All rewrites force-push with `--force-with-lease` against the
  captured old tip, so a push that landed after the clone won't be silently clobbered.

## Prerequisites

- **`git`** — `>= 2.38` for the in-object-store rebase scripts (`drop-commit.sh`,
  `replace-commit.sh`). `drop-commit-merges.sh` only needs `>= 2.24`.
- **`gh`** ([GitHub CLI](https://cli.github.com)) — authenticated with `gh auth login`.
  The token needs **Contents: write** to push.
- **`jq`** — required by `detect-force-push.sh`.
- **`git-filter-repo`** — required by `drop-commit-merges.sh` only.
  Install with `brew install git-filter-repo` or `pip install git-filter-repo`.

## The scripts

| Script | Purpose |
|---|---|
| `detect-force-push.sh` | Scan a repo's recent push events; flag history-rewriting force-pushes; report the BAD (force-pushed head) and GOOD (restore candidate) hashes. |
| `restore-branch.sh` | Force-reset a branch to a known-good SHA. The simplest fix when the bad commits sit at or after the tip. |
| `drop-commit.sh` | Remove one bad commit from **linear** history and replay the commits on top of it. |
| `drop-commit-merges.sh` | Same as `drop-commit.sh`, but works **across merge commits** (uses `git-filter-repo`). |
| `replace-commit.sh` | Replace a bad commit with a different, corrected commit, then replay the rest (`git rebase --onto good bad branch`). |

**Shared options** (all scripts except `detect-force-push.sh`):

- `-y`, `--yes` — skip the confirmation prompt (use with care)
- `-h`, `--help` — show usage

## Usage

### detect-force-push.sh

```bash
./detect-force-push.sh <owner/repo> [branch]

# Examples:
./detect-force-push.sh acme-corp/widget-service
./detect-force-push.sh acme-corp/widget-service dev
```

For each force-push it finds, it prints the BAD hash (the force-pushed head) and the GOOD
hash (the pre-push state you'd restore to).

### restore-branch.sh

```bash
./restore-branch.sh <owner/repo> <branch> <good-sha> [-y|--yes]

# Example:
./restore-branch.sh acme-corp/widget-service dev 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
```

### drop-commit.sh

```bash
./drop-commit.sh <owner/repo> <branch> <bad-sha> [-y|--yes]

# Example:
./drop-commit.sh acme-corp/widget-service dev 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
```

### drop-commit-merges.sh

```bash
./drop-commit-merges.sh <owner/repo> <branch> <bad-sha> [-y|--yes]
```

Use this when `drop-commit.sh` reports that rewriting across merges requires a manual
interactive rebase.

### replace-commit.sh

```bash
./replace-commit.sh <owner/repo> <branch> <bad-sha> <good-sha> [--dry-run] [-y|--yes]

# Example:
./replace-commit.sh acme-corp/widget-service master \
    1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b \
    0f1e2d3c4b5a69788990a1b2c3d4e5f607182930
```

`good-sha` must already be pushed to the remote (on any branch or tag). Pass `--dry-run`
to compute the rewrite and print the old → new tip plus a diffstat without pushing.

## Typical workflow

1. **Find what happened.** Identify the BAD and GOOD hashes:

   ```bash
   ./detect-force-push.sh owner/repo [branch]
   ```

2. **Verify the GOOD hash still resolves** before restoring:

   ```bash
   gh api repos/owner/repo/commits/<GOOD_hash> --jq '{date: .commit.author.date, msg: .commit.message}'
   ```

3. **Apply the fix** that matches the situation:
   - Reset the whole branch back to GOOD → `restore-branch.sh`
   - Drop one bad commit from linear history → `drop-commit.sh`
   - Drop one bad commit when merges are in the way → `drop-commit-merges.sh`
   - Swap a bad commit for a corrected one → `replace-commit.sh`

## Notes & caveats

- **Branch protection.** Force-push will fail on a branch protected against force-pushes —
  temporarily relax the rule, then re-enable it.
- **New SHAs.** Rewritten/replayed commits get **new SHAs**, and any **GPG signatures on
  them are dropped**.
- **Collaborators must reset or re-clone** after any rewrite — their old branch will no
  longer match.
- **Detection window.** `detect-force-push.sh` uses the GitHub Events API, which only
  covers roughly the last **90 days / 300 events**. For older history, use the org audit log.
