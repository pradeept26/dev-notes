---
name: verify-cherry-picks
description: Verify whether commits are actually present on a target branch (master, release branch, etc.) — distinguishing truly-missing from bundled, superseded, intentionally-skipped, or report-noise. Use when asked "is this PR on master?", when given a list of PR numbers to check, before raising redundant cherry-pick PRs, or when triaging a tracker-generated "missing commits" report (CSV/spreadsheet). Output is a Slack-ready triage report with concrete action items.
---

# Verify Cherry-Picks Skill

## Core principle

**Tracker reports and naive branch-diffs are suggestive, not authoritative.** A PR labeled `"Cherrypick not attempted"` (or a SHA absent from `git log target --grep="#<pr>"`) means *that exact PR number wasn't found in any commit subject* — it does NOT mean the change is absent from the target branch.

Before raising a cherry-pick PR, verify the change isn't already on the target branch in some form. False positives are common and waste reviewer time.

---

## Input modes — all equally supported

| Input | First step |
|---|---|
| Single PR# ("is #N on master?") | Skip to Phase 1; go deeper on fingerprint (Phase 2) |
| List of PR numbers | Skip to Phase 1, loop |
| Owner handle + branch pair ("what's missing from master that vdanivas filed on 1.125-a?") | See "Generating candidates" below, then Phase 1 |
| Tracker CSV/spreadsheet | Phase 0 first, then Phase 1 per row |

### Generating candidates when you have no list

If the user has no list and no report — just two branch names and (ideally) an author/path filter — generate the candidate set with:

```bash
git log $TARGET..$SOURCE --no-merges --author=<handle> --pretty='%h %s' | head -100
```

**Always filter.** Unfiltered `target..source` on a release branch returns hundreds of commits across vpp/polaris/iris/etc and is unreadable. At minimum pass `--author=<handle>` or `-- <path>`; ideally both.

---

## Phase 0 — CSV parsing (optional, only if input is a tracker CSV)

Skip this entire phase if the input is a PR list, single PR, or generated candidates.

Tracker CSVs almost always **forward-fill blank owner columns**. The first row in a group has the owner; subsequent rows leave it blank. Naive filtering misses 90%+ of rows.

```python
import csv
with open(csv_path, encoding='latin-1') as f:  # not utf-8 — reports use Windows-1252
    rows = list(csv.DictReader(f))

last = {'Manager': '', 'GIT-Owners': '', 'Owner (AMD Name)': ''}
for r in rows:
    for k in last:
        v = (r.get(k) or '').strip()
        if v: last[k] = v
        else: r[k] = last[k]

# Now filter by owner (use GIT-Owners handle, not display name)
mine = [r for r in rows if (r.get('GIT-Owners') or '').lower() == 'pradeept26']
```

If the file is an **`.xlsx` that won't open with openpyxl** and `file` reports `Composite Document File V2`, it's DRM-encrypted (Microsoft IRM). Ask the user to re-export as CSV — there's no decrypting it.

---

## Phase 1 — Detection cascade (cheap → expensive)

Run these in order. **Stop at the first hit.**

```bash
# Inputs
PR=115541
TARGET=origin/master           # or origin/1.130-a, etc.
SOURCE=origin/1.125-a

# 1a. SHA grep — catches preserved PR# in any commit subject
git log $TARGET --grep="#${PR}\b" --pretty=format:"%h %s" | head -3

# 1b. Inspect bundle PR bodies for the child PR#
#     (CPs are often bundled — e.g. "Hydra: Cherry-pick 11 PRs from 1.125-a (#116017)"
#      hides 11 child PR numbers inside the squash message)
git log $TARGET --pretty=format:"%h %s" --grep="Cherry-pick\|Multiple CPs\|cherry-picks" -i \
  | head -10 \
  | while read sha rest; do
      git log -1 --pretty=format:"%B" $sha | grep -q "#${PR}\b" && echo "BUNDLED IN: $sha $rest"
    done

# 1c. Title grep — catches reworded subjects
TITLE_KEYWORDS="distinctive phrase from PR title"
git log $TARGET --grep="$TITLE_KEYWORDS" --regexp-ignore-case --pretty=format:"%h %s" | head -3

# 1d. patch-id — catches identical patches with completely different commit messages
SRC_SHA=$(git log $SOURCE --grep="#${PR}\b" --pretty=format:"%H" | head -1)
SRC_PID=$(git show $SRC_SHA | git patch-id | awk '{print $1}')
git log $TARGET --since="6 months ago" --pretty=format:"%H" | while read s; do
  p=$(git show "$s" 2>/dev/null | git patch-id 2>/dev/null | awk '{print $1}')
  [ "$p" = "$SRC_PID" ] && echo "PATCH-ID MATCH: $s" && break
done
```

If 1a-1d all miss → continue to Phase 2 (manual fingerprint with LLM judgment).

---

## Phase 2 — Manual fingerprint (LLM judgment)

For each PR not found in Phase 1, do this:

1. **Get the source diff** and pick a distinctive `^+` line:
   - A new `#define` or `#include`
   - A unique comment string ("HACK for now to add coherency...")
   - A new symbol name or field name
   - A specific numeric constant the PR introduces
   
   ```bash
   git show $SRC_SHA | grep -E "^\+" | head -30
   ```

2. **Grep the target branch** for that fingerprint:
   ```bash
   git grep -nE "<distinctive string>" $TARGET -- <path>
   ```

3. **Interpret the result** with judgment:

| What you see on target | Verdict |
|---|---|
| Exact fingerprint present | ✅ Present (likely via refactored CP) |
| Different impl, same intent (e.g. PR raised limit 5→7, master is at 16) | ⚠️ Superseded |
| Opposite of what PR wanted (e.g. PR disables X, master keeps X enabled) | 🛑 Intentionally not applied |
| Fingerprint absent, files don't even exist | ℹ️ Report noise (PR was a CP into source branch from master in the first place) |
| Fingerprint absent, files exist with old behavior | ❌ Truly missing |

**Examples of judgment from past sessions:**
- *PR raised `BITMAP_ALLOCATOR_MAX` from 5 to 7. Master is at 16.* → **Superseded**. The bigger fix already landed.
- *PR disables neighbor-sharing "until verified." Master still calls the enable function.* → **Intentionally not applied**. The "until verified" gate was lifted.
- *PR is titled "Cherry pick X to 1.117.3-a" and originated from master in the first place.* → **Report noise**. Nothing to bring back.
- *PR adds `qos_tdma_alpha_update(3)` for hydra. Master defines `META_ROCE_TDMA_AG_ALPHA=3` and calls `qos_tdma_alpha_update(META_ROCE_TDMA_AG_ALPHA)`.* → **Present** in refactored form.

---

## Phase 3 — Outcome categories

Always categorize every PR into exactly one of these 5 buckets:

| Bucket | Emoji | Action needed |
|---|---|---|
| Present | ✅ | None — close in tracker if possible |
| Superseded | ⚠️ | None — note the superseding PR for reference |
| Intentionally not applied | 🛑 | None — but document WHY in the report |
| Report noise | ℹ️ | None — file tracker bug if recurring |
| Truly missing | ❌ | Raise cherry-pick PR (Phase 5) |

---

## Phase 4 — Slack-ready report format

Generate exactly this structure. Keep it tight — reviewers scan, they don't read.

```
*Missing commits triage (<source> → <target>, fresh master <SHA>) — N PRs across M owners*

❌ Truly missing — needs cherry-pick decision (X)
• #<PR> (<owner>) — <title>
  <one-line fingerprint evidence>

⚠️ Superseded by a different/better fix on master (Y)
• #<PR> (<owner>) — <title> → replaced by #<other PR> (<reason>)

🛑 Intentionally not applied (Z)
• #<PR> (<owner>) — <title>
  <why master deliberately differs>

ℹ️ Report noise (W)
• #<PR> (<owner>) — <reason>

✅ Already on master (Q)
• <owner>: <PR list> (via bundle #<bundle PR>)
• <owner>: <PR list> (functionally present — <how>)
```

Group ✅ Present items by owner+bundle to keep the section short.

---

## Phase 5 — Raising cherry-pick PRs (if needed)

Only for ❌ Truly missing items. Confirm with user first.

### Use worktrees to avoid disturbing current checkout

```bash
git worktree add /tmp/cp-<PR>-<branch> -b cp/<PR>-<branch> origin/<branch>
cd /tmp/cp-<PR>-<branch>
git cherry-pick -x <SRC_SHA>          # -x adds "(cherry picked from commit ...)" trailer
```

### Preserve original authorship

`git cherry-pick` keeps the original Author; you become Committer. This is standard practice for credit/blame. Don't override author unless the user asks.

### Push to personal fork, raise PR against upstream

```bash
# Repo's origin usually points to pensando/sw which most people can't push to.
# Add your fork as a separate remote.
git remote add fork git@github.com:<your-handle>/sw.git
git push -u fork cp/<PR>-<branch>

gh pr create -R pensando/sw \
  --base <branch> \
  --head <your-handle>:cp/<PR>-<branch> \
  --title "[CP <PR>] <original title>" \
  --body "..."
```

### Add CI labels via REST API, NOT `gh pr edit`

`gh pr edit --add-label` hits a deprecated projects-classic GraphQL path and silently no-ops on this repo. Use:

```bash
gh api -X POST repos/pensando/sw/issues/<PR>/labels \
  -f labels[]="CI-Precheckin-Hydra" -f labels[]="CI-run"
```

### Cleanup

```bash
cd /<original-dir>
git worktree remove --force /tmp/cp-<PR>-<branch>
```

---

## Gotchas (don't waste time re-discovering these)

- **CSV uses Windows-1252 (`latin-1`), not UTF-8.** Plain `csv.DictReader(open(path))` crashes on byte 0x85.
- **CSV forward-fills owner columns.** Without forward-fill, you'll miss 90%+ of rows.
- **DRM-encrypted `.xlsx` files** look like normal xlsx to the filesystem but contain `EncryptedPackage` OLE streams. Ask for CSV.
- **`gh pr edit --add-label` silently fails** on pensando/sw due to projects-classic GraphQL deprecation. Use REST API.
- **`git worktree` operations can wipe out a few seconds.** Don't run interactive commands in `/tmp/cp-*` paths until the worktree is fully set up.
- **Bundle PR subjects don't preserve child PR numbers in the SUBJECT** — they're only in the BODY. SHA-grep with `--grep` searches both, but only if you don't restrict scope.
- **A PR titled `"Cherry-pick X to 1.117.3-a"`** likely originated from master, was cherry-picked INTO the source branch, and never needed to "come back" to master. Always check origin direction.

---

## Quick-start

### Common case: "is #N on master?" (single PR)

```bash
git fetch origin master 1.125-a 2>&1 | tail -2
PR=115541; TARGET=origin/master; SOURCE=origin/1.125-a

# Phase 1 cascade
git log $TARGET --grep="#${PR}\b" --pretty=format:"%h %s" | head -3
# If empty, fingerprint:
sha=$(git log $SOURCE --grep="#${PR}\b" --pretty=format:"%H" | head -1)
git show $sha | grep -E "^\+" | head -20    # pick a distinctive line
git grep -n "<distinctive line>" $TARGET -- <path>
```

### List of PRs

```bash
for pr in $PR_LIST; do
  hit=$(git log origin/master --grep="#${pr}\b" --pretty=format:"%h %s" | head -1)
  echo "PR #$pr: ${hit:-MISSING}"
done
# Then run Phase 2 fingerprint on each MISSING entry; categorize via Phase 3; report via Phase 4
```

### CSV tracker report

```bash
git fetch origin master 1.125-a 1.130-a 2>&1 | tail -5
# Phase 0: parse CSV with forward-fill (Python snippet above), extract PR# list per owner
# Phase 1 → Phase 2 → Phase 3 → Phase 4 as above
```

### Always end with

```bash
# Confirm with user before raising any CP PRs (Phase 5)
```

---

## Why this skill exists

A naive branch-diff (`git log A..B --no-merges`) is what the tracker tools do — and it overcounts "missing" by ~5x in real sessions because:

1. Bundled cherry-pick PRs hide 10+ child PR numbers in their squash messages
2. PRs can land in functionally-equivalent refactored form (e.g. a `qos_tdma_alpha_update(2)` PR being superseded by removing the whole call)
3. Some PRs are "missing" only because the fix was intentionally lifted (the "until verified" workaround is no longer needed)
4. Some PRs were themselves cherry-picks INTO the source branch and have nothing to bring back

The detection cascade + manual fingerprint + outcome buckets convert tracker noise into a small list of real actions.
