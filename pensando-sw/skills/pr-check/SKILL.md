---
name: pr-check
description: "Check pensando/sw PR CI status, drill into failed jobd jobs, fetch console logs, distinguish PR-induced regressions from pre-existing master failures, and apply known fix patterns. Triggers: check pr, pr status, ci status, why is my pr failing, jobd debug, pr ci, what's wrong with my pr."
---

# PR-Check Skill (pensando/sw + jobd CI)

End-to-end workflow for investigating CI on a `pensando/sw` PR:
1. Get the failing checks
2. Drill into the failed jobd targets
3. Fetch the actual console log
4. Decide: PR-induced regression vs pre-existing master failure
5. Apply or recommend a known fix pattern
6. Re-trigger CI when needed

## Input

The user's arguments are: `$ARGUMENTS` — one of:

| Argument | Action |
|---|---|
| `<number>` (e.g. `116017`) | Check that specific PR |
| (empty) | Auto-detect: first try current branch's PR; if none, fall through to "recent" mode |
| `recent` | **Default scope** — only PRs at most **30 days old** (created within last month). Summary table; drill into failures on request |
| `all` or `mine` | **Every** open PR the user owns regardless of age. Summary table only |
| `<branch-name>` | Resolve to its open PR via `gh pr list --head <branch>` |

**"Recent" means ≤ 30 days old** (by createdAt). Anything older is excluded from the summary unless `all`/`mine` is passed. This keeps the noise down — stale PRs (months old, often blocked on `ReleaseApproved`) don't drown out active work.

### Resolution logic

```bash
ARG="$ARGUMENTS"

if [ -z "$ARG" ]; then
  # 1. Try current branch
  PR=$(gh pr list --head "$(git branch --show-current)" --state open \
       --json number --jq '.[0].number // ""' 2>/dev/null)

  if [ -z "$PR" ]; then
    # 2. List all user's open PRs and pick
    gh pr list --author "@me" --state open \
      --json number,title,headRefName,statusCheckRollup \
      --jq '.[] | {number, title, branch: .headRefName,
                   has_failure: ([.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .state=="failure")] | length > 0)}'
    # Ask user to pick one (or pass "all")
  fi

elif [ "$ARG" = "all" ] || [ "$ARG" = "mine" ]; then
  # All open PRs, regardless of age
  PRS=$(gh pr list --author "@me" --state open --json number --jq '.[].number')

elif [ "$ARG" = "recent" ] || [ -z "$ARG" ]; then
  # Only PRs created in the last 30 days.
  # NOTE: gh CLI's --jq does NOT support jq's --arg flag, so pipe to a
  # separate jq for the date filter rather than inlining the cutoff.
  CUTOFF=$(date -u -d "30 days ago" +%Y-%m-%dT%H:%M:%SZ)
  PRS=$(gh pr list --author "@me" --state open --json number,createdAt \
        | jq --arg c "$CUTOFF" -r '.[] | select(.createdAt >= $c) | .number')
  # Iterate: print a one-line status per PR; ask which to drill into

elif echo "$ARG" | grep -qE '^[0-9]+$'; then
  PR="$ARG"

else
  # Treat as branch name
  PR=$(gh pr list --head "$ARG" --state open --json number --jq '.[0].number')
fi
```

### Multi-PR summary mode (`all` / `mine`)

For each PR, print one line:

```
PR    branch                     state    failing-checks    last-fail-reason
116017 cherry-pick-hydra          fail     2                 invalid .job.yml
116041 hydra-vulcano-ts-csr       pending  0                 (all queued)
```

Then ask: "drill into PR #X?" before running Phase 2–5 on any one of them.

In `all` mode, never auto-fix — just report. Drilling-with-fix needs explicit per-PR confirmation.

---

## Phase 1 — Get the failing checks

### 1a. Quick summary (CLI):
```bash
gh pr checks <PR> --repo pensando/sw
```
Outputs `name | state | duration | url`. Three states matter:
- `fail` — needs investigation
- `pending` — still running
- `pass` — done, ignore

### 1b. Detailed status with descriptions (REST API):
```bash
SHA=$(gh pr view <PR> --repo pensando/sw --json statusCheckRollup,headRefOid \
  --jq '.commits[-1].oid // .headRefOid' 2>/dev/null \
  || gh pr view <PR> --repo pensando/sw --json commits --jq '.commits[-1].oid')

gh api repos/pensando/sw/commits/$SHA/statuses \
  --jq '.[] | {context, state, description, url: .target_url}'
```
The `description` field is the gold — it carries jobd's error string when the check failed before the actual build ran (e.g. "invalid .job.yml").

**Output `gh pr checks` is also useful — and faster than the API**, but it doesn't show the `description`. Use the API when you need to know WHY a check failed.

---

## Phase 2 — Drill into failed jobd targets

The `*root*` job is the parent. Other entries like `devops/jobs/level1/...` are sub-jobs. URLs look like `http://jobd.pensando.io/job/<ID>`.

### 2a. jobd Web UI is a SPA — must use backend port 3456:

| Endpoint | What you get |
|---|---|
| `http://jobd.pensando.io:3456/job/<job_id>` | Root job JSON: status, all sub-targets, exit codes, runner host, timing |
| `http://jobd.pensando.io:3456/target/<target_id>` | One sub-target's JSON (smaller) |
| `http://jobd.pensando.io:3456/logs/<target_id>` | **Raw console log** (this is what you want) |

The job_id is the number from `http://jobd.pensando.io/job/<NNNN>` URL. The target_id is per-sub-job, found inside the root JSON's `.Targets[].ID`.

### 2b. Fetch root job + filter failures:
```bash
JOBID=<NNNN>
curl -sS --max-time 30 "http://jobd.pensando.io:3456/job/$JOBID" -o /tmp/rootjob.json

# Summary
jq '{ID, Status, Finished,
     total: (.Targets|length),
     pass:  [.Targets[] | select(.Success==true)]  | length,
     fail:  [.Targets[] | select(.Success==false)] | length}' /tmp/rootjob.json

# Failing targets with their IDs and exit codes
jq '.Targets[] | select(.Success==false) |
    {ID, Name, ExitCode, RanOn, Target: (.Target|join(" "))}' /tmp/rootjob.json
```

### 2c. Exit code legend:
| ExitCode | Meaning |
|---|---|
| `0` | Success (but `Success==false` if cancelled/aborted) |
| `12` | **Real build failure** — investigate logs |
| `502` | **Cascade failure** — a dep target failed; not the root cause |
| other | Read the log; usually script-specific |

Always start with exit-12 targets. Exit-502 targets are downstream effects.

### 2d. Fetch console log for a failing target:
```bash
TID=<target_id from .Targets[].ID>
curl -sS --max-time 60 "http://jobd.pensando.io:3456/logs/$TID" -o /tmp/log_$TID.txt
wc -l /tmp/log_$TID.txt

# Surface real errors only, filter common noise
grep -iE "^Error|error:|undefined reference|fatal error|recipe.*failed|make.*Error" /tmp/log_$TID.txt \
  | grep -vE "fatal\.c\.obj|safe.directory|dubious ownership|-Wno-error" \
  | head -20
```

---

## Phase 3 — Distinguish PR regression vs pre-existing master failure

**Critical step.** If the same target is also failing on master with the same error, it's NOT your PR's fault — don't try to fix it.

### 3.0 First-pass triage by ASIC (apply before deep diff)

For **hydra-related PRs**, the relevant ASICs are **salina** and **vulcano**. Hydra doesn't target elba/capri, so failures on those ASICs are default-ignored.

| Check path pattern | Default classification for hydra PRs |
|---|---|
| `…/salina/…` or `…/vulcano/…` | **REAL** — investigate |
| `…/elba/…` or `…/capri/…` | **IGNORED** (hydra doesn't target these) |
| `nic` (top-level Go-tests context, iris/dscagent) | IGNORED unless your PR touches `nic/agent/dscagent/` |

For non-hydra PRs (pulsar, quasar, iris), invert as needed — these rules are pipeline-specific.

### 3.0.1 Known-ignorable `*root*` sub-target names (hydra/vulcano PRs)

These are elba sim builds that frequently env-flake (docker registry, missing tarballs, kernel modules). If they fail and the log shows env/build-tarball/docker issues — not a code error — classify as **IGNORABLE** without master comparison:

```
*root*/build-rudra-sim-classic_rtr
*root*/build-rudra-sim-classic_host_offload
*root*/build-rudra-sim-hello_world
*root*/build-rudra-sim-dragon
*root*/build-rudra-sim-flow_offload
*root*/build-rudra-sim-flow_ha
*root*/build-rudra-sim-sdn_policy_offload
*root*/build-rudra-sim-ipsec_gw
*root*/build-rudra-sim-sai
*root*/build-rudra-elba-all
*root*/build-dss-x86-elba
```

Plus the top-level checks: `nic` (iris flake), `devops/jobs/level1/rudra/elba/*`, `test/ci_targets/dss-e2e`.

### 3.0.2 Known master baseline regressions

These specific failures are caused by past merged PRs, not your code. Don't waste time investigating:

| Failing target | Caused by | Verdict |
|---|---|---|
| `devops/jobs/level1/rudra/salina/test/hydra/sim` (`hydra-salina-p4plus-ut` budget mismatch, 74/95 vs 73/93) | PR #115955 (commit `c001511edf0` "Multiple CPs from 1.125.0-a to master") | IGNORABLE — affects every PR against current master |

When citing in a Slack/PR comment, include the introducing PR and commit so reviewers don't re-litigate.

### 3a. Find the most recent master CI run for the SAME target:
```bash
TARGET_NAME="*root*/build-rudra-salina-hydra-ainic-nicctl"  # the failing one

# Get latest master commit on origin
MASTER_SHA=$(git rev-parse origin/master)

# Find the jobd job that built master at that SHA
gh api "repos/pensando/sw/commits/$MASTER_SHA/statuses" \
  --jq '.[] | select(.context=="*root*") | {state, target_url}' | head -3
```
The `target_url` will look like `http://jobd.pensando.io/job/<MASTER_JOBID>`.

### 3b. Fetch master's job JSON and look for the same target:
```bash
MASTER_JOBID=<from above>
curl -sS "http://jobd.pensando.io:3456/job/$MASTER_JOBID" -o /tmp/masterjob.json

# Did the same target also fail on master?
jq --arg name "$TARGET_NAME" \
   '.Targets[] | select(.Name==$name) | {Success, ExitCode, ID}' /tmp/masterjob.json
```

### 3c. Compare error signatures:
If master also failed the same target, fetch master's log for that target ID and diff the error patterns:
```bash
MASTER_TID=<from previous>
curl -sS "http://jobd.pensando.io:3456/logs/$MASTER_TID" -o /tmp/master_log.txt

# Extract just the error lines (head/tail context)
grep -iE "error:|recipe.*failed" /tmp/log_$TID.txt > /tmp/pr_errors.txt
grep -iE "error:|recipe.*failed" /tmp/master_log.txt > /tmp/master_errors.txt

diff /tmp/pr_errors.txt /tmp/master_errors.txt
```

### 3d. Decision matrix:
| Master same target status | Same error signature? | Verdict |
|---|---|---|
| Passing | (n/a) | **Your PR introduced it** — fix the code |
| Failing | Identical | **Pre-existing master regression** — file separately, don't block your PR |
| Failing | Different | **Your PR amplified or shifted it** — review carefully |
| No recent build for that target | (n/a) | Can't compare; treat as PR-induced until proven otherwise |

### 3e. Also do a local code-touch check:
```bash
# Does your PR even touch the file that's failing?
FAILING_FILE="nic/infra/ainic/nicctl/pipeline/hydra/rdma_queue.cc"
git log --oneline origin/master..HEAD -- "$FAILING_FILE"
```
If you don't touch the failing file AND the error is generic (e.g. flaky test, missing asset), it's likely not your bug.

---

## Phase 4 — Known fix patterns (lookup table)

| Symptom | Root cause | Fix |
|---|---|---|
| `error: format '%x' expects ... 'unsigned int', but argument N has type 'long unsigned int' [-Werror=format=]` on a P4-generated bit-field | P4 generates small `bit<N>` fields as bit-fields backed by `uint64_t`. `%x` then mismatches on x86_64. | Cast the read site to `(uint32_t)`: `PATH_ANOMALY("...0x%x", (uint32_t)pcb->field);` |
| `Firmware Config images not found` / `ls: cannot access .../riscv/sim/.../firmware_config*` during gtest build | Zephyr cmake cache rejects board change (e.g. `vulcano_gelso` → `vulcano_sw_emu`). | `rm -rf /sw/platform/rtos-sw/build /sw/platform/rtos-sw/external/ainic-rtos/build` then re-run gtest build |
| job-check fails with `invalid .job.yml: GET https://api.github.com/.../contents/...` (different file each retry) | Transient GitHub API hiccup as jobd iterates all `.job.yml` files (private fork rate-limit/race). Each retry progresses further. | Amend + force-push 1–3 times: `git commit --amend --no-edit --date=now && git push --force-with-lease pradeept26 <branch>` |
| `Lif Get Failed, fetching from logs` / `lif1: invalid devcmd addr!` / `Assertion '0' failed at lib_driver.cc:195` from hydra_gtest | Stale qemu/zephyr/vul_model processes from a previous run; gtest harness reads partial logs and crashes. | `docker exec <container> pkill -9 qemu-system-ri vul_model zephyr.exe pds_dp_app pds_core_app`, then re-run the gtest |
| `ws-tools` patch fails during `make pull-assets` (`vendor/golang.org/x/tools/.../walk.go: patch does not apply`) | Vendored Go tool patch is stale — vendor file was updated upstream. | **Ignore for firmware builds** — `ws-tools` is non-blocking. The actual asset download succeeds. Verify by checking `/sw/platform/ainic/assets/vulcano/` exists. |
| `fatal: detected dubious ownership in repository at '/sw/platform/rtos-sw/external/ainic-rtos'` | Submodule path not in git `safe.directory` allowlist; `safe.directory /sw` covers root but not submodules. | Inside container: `git config --global --add safe.directory '*'` or add specific submodule paths. Often benign (build still works). |

---

## Phase 5 — Apply fix and re-trigger CI

### 5a. Local-first verification
For any code change, **build the exact target that CI failed on** locally before pushing. For nicctl:
```bash
docker exec -w /sw <container> rm -rf /sw/nic/build/x86_64
docker exec -w /sw <container> make -f Makefile.build build-rudra-salina-hydra-ainic-nicctl
```
Wait for clean exit; check artifact (e.g. `/sw/rudra_salina_hydra_host_nicctl_pkg.tar.gz`).

### 5b. Commit strategy:
- If the fix logically belongs to one cherry-picked commit, squash it: `git commit --fixup=<commit_sha>` then `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash origin/master`
- Otherwise just commit normally on top.

### 5c. Force-push:
```bash
git push --force-with-lease pradeept26 <branch>
```

### 5d. Re-trigger CI without content change (for job-check flakes):
```bash
git commit --amend --no-edit --date=now
git push --force-with-lease pradeept26 <branch>
```
Same SHA-tip-change semantics, no behavior change.

### 5d.bis Rerun a single jobd sub-target without re-pushing

When only one sub-target flaked (e.g. `classic_rtr` env issue), don't re-push the whole branch — rerun just that target via jobd's POST endpoint:

```bash
TID=<failing target ID from .Targets[].ID>
curl -sS -X POST "http://jobd.pensando.io:3456/target/$TID/rerun"
```

The rerun produces a NEW target ID; the original failure stays in the job's history. The PR's surface status updates once the rerun's result rolls up. Use this when:
- Failure is an env flake (docker pull failure, missing tarball, transient API error)
- You've already classified it as IGNORABLE
- Your code is unchanged and you just want CI to re-attempt

**Limit**: at most **1 auto-rerun per (PR, target Name)** — if the rerun also fails on the same flake, accept the failure and move on. Repeated reruns spam the queue and don't fix the underlying env issue.

### 5e. Watch new run:
```bash
NEW_SHA=$(git rev-parse HEAD)
sleep 60
gh api "repos/pensando/sw/commits/$NEW_SHA/statuses" \
  --jq '.[] | {context, state, description}' | jq -s 'group_by(.context) | map(.[0])'
```

---

## Phase 6 — Reporting

When done, summarize for the user:
- **Failing check + target** (with jobd URL)
- **Root cause** (one-sentence)
- **Master-comparison verdict** (PR-induced / pre-existing / shifted)
- **Fix applied** (file + line, what changed)
- **Local-build verification result**
- **Push result** (new SHA, link)
- **Next step** (wait for CI / address other failures / ready for review)

---

## Gotchas

- **`gh pr edit` may fail with GraphQL "Projects (classic) deprecated" warning** that aborts the operation. Workaround: use the REST API directly:
  ```bash
  gh api -X PATCH repos/pensando/sw/pulls/<PR> -f title="..." -f body="..."
  # or with --input /tmp/body.json for large bodies
  ```
- **`gh pr ready <PR>`** works (different code path), can mark drafts ready without the GraphQL issue.
- **Slack tools missing entirely (`mcp__plugin_agentq_slack__*` not in toolset)** — this is a stale plugin install pointer, NOT an OAuth issue. Check `~/.claude/plugins/installed_plugins.json` for the agentq entry — if `installPath` references a version that no longer exists in `~/.claude/plugins/cache/ntsg_claude_plugins/agentq/`, update the JSON entry to point at the version that IS in cache, then exit and resume the session. Example: cache has `0.2.0` but JSON says `0.1.0` — jq-edit `version` and `installPath` to `0.2.0`, then `claude -c`.
- **Slack tagging**: use `<@USERID>` (e.g. `<@U5W982WKW>`) for proper mentions, NOT `@username`. Look up the ID first via `mcp__plugin_agentq_slack__slack_search_users`.
- **`/sw/build/x86_64` ≠ full clean**. For nicctl validation it's enough; for full re-builds use `make -f Makefile.ainic clean`.
- **jobd doesn't accept comment-based retries** (`/retest`, `/recheck`) on this repo — use amend + force-push.
- **Private-fork auth quirk**: jobd CAN fetch files from `pradeept26/sw` (a private fork) for *most* operations, but its sub-`.job.yml` traversal in job-check sometimes 404s on transient API issues. Retrying clears it.

## Quick recipe summary

```bash
PR=116017
SHA=$(gh pr view $PR --repo pensando/sw --json commits --jq '.commits[-1].oid')

# 1. failing checks
gh api repos/pensando/sw/commits/$SHA/statuses \
  --jq '.[] | select(.state=="failure") | {context, description, target_url}'

# 2. root job analysis
JOBID=<from target_url>
curl -sS http://jobd.pensando.io:3456/job/$JOBID -o /tmp/rj.json
jq '.Targets[] | select(.Success==false and .ExitCode==12) |
    {ID, Name, ExitCode}' /tmp/rj.json

# 3. actual error
TID=<failing ID>
curl -sS http://jobd.pensando.io:3456/logs/$TID -o /tmp/lg.txt
grep -iE "error:|recipe.*failed" /tmp/lg.txt | head -10

# 4. is master broken the same way?
MASTER_SHA=$(git rev-parse origin/master)
MJOB=$(gh api repos/pensando/sw/commits/$MASTER_SHA/statuses \
       --jq '.[] | select(.context=="*root*") | .target_url' \
       | head -1 | grep -oP '\d+')
curl -sS http://jobd.pensando.io:3456/job/$MJOB -o /tmp/mj.json
jq --arg n "$TARGET_NAME" \
  '.Targets[] | select(.Name==$n) | {Success, ExitCode}' /tmp/mj.json

# 5. apply fix, build locally, push
git push --force-with-lease pradeept26 $(git branch --show-current)
```
