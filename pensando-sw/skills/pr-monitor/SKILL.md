---
name: pr-monitor
description: "Long-running, durable, autonomous monitor for one or more pensando/sw PRs. Sets up a cron that polls jobd until a user-defined completion criterion is met, auto-reruns ignorable env flakes, escalates real failures via Slack DM, and posts a final summary to a group chat on completion before self-deleting. Survives Claude session restarts. Triggers: watch my PRs, monitor PRs, babysit PRs, notify me when CI is done, ping me when PR sanity passes."
---

# PR-Monitor Skill (background, durable, slack-notified)

Companion to `pr-check` — that skill is **one-shot** triage. This one is **continuous** until done.

## When to use

- "monitor my PRs and ping me when both pass sanity"
- "set up a watch on PR #X — auto-rerun any env flakes, DM me if anything real fails"
- "post to <group chat> when CI finishes"
- "I'm logging off — keep an eye on these and let me know"

Not for one-shot status. For that, use `pr-check`.

## Inputs to elicit (or default)

| Input | Default | Note |
|---|---|---|
| **PR list** | (must ask) | e.g. `116017, 116041` |
| **Completion criterion** | "both PRs' `*root*` jobs closed" | Other options: "all PR checks pass", "specific named check passes" |
| **Out-of-scope checks** | (must ask) | E.g. for hydra/vulcano PRs: elba e2e/sim, dss-e2e, elba gtest — see `pr-check` Phase 3.0 |
| **Notify channel** | (must ask) | Slack group chat ID (e.g. `C0B494HHS8Z`) AND user DM ID |
| **Tag user** | (must ask) | Slack `<@USERID>` to ping in the final post |
| **Auto-rerun policy** | "1× per (PR, target Name) for ignorable env flakes" | Use jobd `POST /target/<id>/rerun`, never re-push code |
| **Poll cadence** | 15 min | `7,22,37,52 * * * *` (avoid :00/:30) |
| **Timeout** | 8 hours | After this, post a "timeout — manual review" message and exit |

## State file

Persist in `~/.claude/pr-monitor-state.json` (NOT `/tmp/` — survives reboot).

Minimal schema:
```json
{
  "monitor_started_at": "ISO-8601",
  "iteration": <int>,
  "last_iteration_at": "ISO-8601",
  "posted": false,
  "completion_rule": "<human description>",
  "current_cron": "<cron id from CronCreate>",
  "slack_unavailable": false,
  "pr_<NNN>": {
    "asked_about": {"target_name": "dm_ts"},
    "user_replied": {"target_name": "decision"},
    "auto_rerun_done": {"target_name": "new_target_id"}
  }
}
```

Write atomically: `jq '...' state.json > /tmp/s.tmp && mv /tmp/s.tmp state.json`.

## Setup workflow (one-time, on first invocation)

1. Resolve all inputs above. Use `AskUserQuestion` if any are ambiguous.
2. Initialize state file (don't clobber if it already exists and `posted == false` — resume instead).
3. Build the cron prompt (template below — substitute the elicited values).
4. Call `CronCreate` with `recurring: true`, `durable: true`, schedule `7,22,37,52 * * * *` (or as requested).
5. Save the returned cron id into state as `current_cron`.
6. Confirm to user: cron id, cadence, completion rule, where the final post will land, that it survives Claude restart.
7. **Run the first iteration immediately** — don't wait 15 minutes to surface any obvious issue.

## Cron prompt template

The cron prompt is what fires every iteration. Make it self-sufficient — it must work even after Claude restart (state file is the only continuity).

```
Monitor PRs <PR_LIST> until <COMPLETION_CRITERION>, then post final summary
to group chat <GROUP_CHANNEL_ID> tagging <USER_MENTION>, DM <USER_DM_ID>, and exit.

State file: ~/.claude/pr-monitor-state.json. Read at start, write at end.
If missing, initialize {iteration: 0, posted: false}.

## Per-iteration steps

1. Increment .iteration, set .last_iteration_at to current UTC.

2. For each PR:
   - SHA=$(gh pr view <PR> --repo pensando/sw --json commits --jq '.commits[-1].oid')
   - Find *root* status target_url, extract JOBID
   - curl -sS http://jobd.pensando.io:3456/job/$JOBID -o /tmp/rj_<PR>.json
   - Compute: pass=[.Targets[]|select(.Success==true)]|length,
              fail=[.Targets[]|select(.Success==false)]|length,
              running=[.Targets[]|select(.Success==null and (.Finished==null or .Finished=="0001-01-01T00:00:00Z"))]|length
   - root_done = (running == 0) OR (.Status in {"completed","finished","done","success","failure"})

3. Completion criterion: <DESCRIBE>. Skip checks listed in <OUT_OF_SCOPE>.

4. Auto-rerun for ignorable failures (1× per (PR, target Name), record in state.pr_<PR>.auto_rerun_done):
   - For each *root* sub-target with Success==false, classify:
     - Name matches <IGNORABLE_PATTERNS> AND log shows env/build-tarball/docker issue → IGNORABLE
     - Name matches `salina/test/hydra/sim` → master baseline PR #115955 commit c001511edf0 — IGNORABLE
     - Name matches `nic` → known iris flake — IGNORABLE
     - Other → genuine failure. DM user the failing target ID + log tail; do NOT auto-rerun.
   - For IGNORABLE: rerun via `curl -sS -X POST http://jobd.pensando.io:3456/target/$TID/rerun`,
     record new target ID in auto_rerun_done. If already rerun once, skip — don't spam.

5. One-line per-iteration log to stdout (no DM unless action needed).

## Final post (when criterion met and state.posted == false)

Build summary from /tmp/rj_*.json. Template:

```
Hi <USER_MENTION> — sanity status update on <PR_DESCRIPTION>:

✅ PR #<N> (<branch>) — sanity complete
https://github.com/pensando/sw/pull/<N>
• *root* build job: <pass>/<total> pass, <fail> fail
• Known-ignorable failures:
    - <list>
... repeat per PR ...

Both PRs are ready for review.
```

If ANY genuine failure exists, change ✅ to ⚠️ and list the offending sub-targets.

Steps:
- Look up <USER_MENTION> ID via mcp__plugin_agentq_slack__slack_search_users if not known
- Post to <GROUP_CHANNEL_ID> via mcp__plugin_agentq_slack__slack_send_message
- Send a copy as DM to <USER_DM_ID>
- Set state.posted=true, state.posted_at=now, state.group_post_link=<link>
- CronDelete <CRON_ID> — exit cleanly.

## Slack tool fallback

If slack tools missing (mcp__plugin_agentq_slack__* not in toolset):
- Set state.slack_unavailable=true, save state
- Print message text to stdout for user to paste manually
- Do NOT mark posted=true (retry next iteration; tool may recover via plugin fix)
On success: set state.slack_unavailable=false.

## Guardrails

- 8-hour timeout: if (now - monitor_started_at) > 8h, post "timeout — manual review" and exit.
- Max 1 auto-rerun per (PR, target Name). Record in state.
- NEVER re-trigger CI via amend/force-push — only jobd target reruns.
- Be terse in iteration logs; verbose only at final post or when DMing user.
```

## Per-iteration runbook (what to actually do each fire)

This is what executes inside the cron prompt above. The cron is just a kick — the work is here.

### 1. Read state
```bash
cat ~/.claude/pr-monitor-state.json | jq '.'
```
If `posted == true`, do nothing — cron should have already been deleted, but defensive.

### 2. Per-PR status pull
```bash
for PR in <list>; do
  SHA=$(gh pr view $PR --repo pensando/sw --json commits --jq '.commits[-1].oid')
  URL=$(gh api "repos/pensando/sw/commits/$SHA/statuses?per_page=100" \
    | jq -r 'group_by(.context) | map(max_by(.created_at)) | map(select(.context=="*root*")) | .[].target_url')
  JOBID=$(echo "$URL" | grep -oP '\d+$')
  curl -sS --max-time 30 "http://jobd.pensando.io:3456/job/$JOBID" -o /tmp/rj_$PR.json
done
```

### 3. Compute root_done per PR
```bash
jq -r '{
  Status,
  total: (.Targets|length),
  pass: [.Targets[]|select(.Success==true)]|length,
  fail: [.Targets[]|select(.Success==false)]|length,
  running: [.Targets[]|select(.Success==null and (.Finished==null or .Finished=="0001-01-01T00:00:00Z"))]|length
}' /tmp/rj_$PR.json
```
**root_done = (running == 0)**. Status string is "running" / "success" / "failure" — failure with all targets finished still counts as done.

### 4. Classify failures per `pr-check` Phase 3.0 / 3.0.1 / 3.0.2

Run pr-check's classification table. Build a per-target verdict: IGNORABLE / REAL / UNKNOWN.

### 5. Auto-rerun decisions

For each IGNORABLE failure NOT already auto-rerun:
```bash
TID=<failing target ID>
curl -sS -X POST "http://jobd.pensando.io:3456/target/$TID/rerun"
# record in state: state.pr_$PR.auto_rerun_done[<name>] = <new TID>
```

For REAL failures: send DM to user with target ID + log tail:
```bash
LOG=$(curl -sS "http://jobd.pensando.io:3456/logs/$TID" | grep -iE "error:|recipe.*failed" | head -10)
mcp__plugin_agentq_slack__slack_send_message --channel_id <USER_DM> --message "..."
```
Record in `state.pr_$PR.asked_about[<name>] = <message_ts>` so future iterations don't re-spam.

### 6. Completion check

If ALL PRs root_done AND state.posted == false:
- Build summary message (template above)
- Look up tag user ID via `mcp__plugin_agentq_slack__slack_search_users` if needed
- Post to group channel
- DM user the post link
- Mark state.posted=true, state.posted_at=now, state.group_post_link=<link>
- Call `CronDelete <current_cron>` to self-terminate

### 7. Write state

Always rewrite state at end of iteration (even if no posting happened):
```bash
jq '.iteration += 1
   | .last_iteration_at = "<NOW>"
   | .last_check = {pr_<N>: {...}, ...}' state.json > /tmp/s.tmp && mv /tmp/s.tmp state.json
```

## Resume after Claude restart

The cron persists via `durable: true` (lives in `.claude/scheduled_tasks.json`). On Claude restart:
- Cron auto-loads.
- State file is intact at `~/.claude/pr-monitor-state.json`.
- On next fire, the prompt re-reads state and continues seamlessly.

**Caveat**: crons only fire while the REPL is idle. If Claude is closed, fires during the gap are NOT queued — they just resume on the next schedule when Claude is open again. Tell the user this when setting up.

## How to verify monitor health

`CronList` should show your cron id. State file's `last_iteration_at` should be within the past `(poll_cadence + 5min)` while Claude is open. If stale, it means iterations failed silently — check the last iteration log.

## Patterns + IDs reference

| Item | Value |
|---|---|
| pensando/sw fork (pradeept) | `pradeept26/sw` |
| jobd base | `http://jobd.pensando.io:3456` |
| Endpoints | `/job/<id>`, `/target/<id>`, `/logs/<id>`, `POST /target/<id>/rerun` |
| Master baseline regression | PR #115955, commit `c001511edf0` ("Multiple CPs from 1.125.0-a to master"); affects `salina/test/hydra/sim` |
| Group chat C0B494HHS8Z | Hydra core team |
| Pradeep DM | D022B45MVJ7 (user U02244G2UJJ) |
| Balakrishnan Raman | U5W982WKW (tag as `<@U5W982WKW>`) |

## Gotchas (see pr-check skill for more)

- **Slack tagging**: `<@USERID>` (e.g. `<@U5W982WKW>`), NOT `@username`. Always look up via `slack_search_users` first.
- **Don't pick cron minutes :00 or :30** — adds load to the API at the same instants as every other cron in the fleet. Use :07/:22/:37/:52.
- **Self-delete on completion** is critical — otherwise the cron keeps firing for 7 days. The cron prompt must call `CronDelete` itself.
- **Stale slack flag**: if a previous session marked `slack_unavailable=true` but tools are back, clear the flag manually:
  ```bash
  jq '.slack_unavailable = false' state.json > /tmp/s.tmp && mv /tmp/s.tmp state.json
  ```
- **Plugin install drift can kill slack tools** — if `installed_plugins.json` points at a cache version that no longer exists, slack tools disappear from toolset even though `claude mcp list` shows connected. Fix via jq edit + restart (see `pr-check` skill Gotchas).

## Companion skill

For one-shot status, failure drill-down, baseline comparison, and fix patterns: use `pr-check`. This skill (`pr-monitor`) is intended for **long-running, background, notify-when-done** scenarios — typically when the user is about to log off.
