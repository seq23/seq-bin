# ~/bin — scheduled machinery

Scripts that run unattended under `launchd` on this Mac. They exist because
some work cannot run in a Claude Code agent: **the agent runner strips every
environment variable matching `KEY|TOKEN|SECRET|PASSCODE`**, so anything that
needs the vault, the mailbox, Search Console or the `gh` login runs from here
instead.

Version controlled from 2026-09-08. Before that there was no history, and a bad
edit was recoverable only if someone had thought to copy the file first.

## What's here

| Script | Schedule | What it does |
|---|---|---|
| `ci-sweep.sh` | Monday and Friday at 08:00 CT (`launchd/com.seq.ci-sweep.plist`; owner's decision 2 Oct 2026, first run Mon 5 Oct), with one retry at 09:00 the same day if not green (`launchd/com.seq.ci-sweep-retry.plist` → `ci-sweep-retry-if-red.sh`) | Goal: every repo's main green. Probes the fleet, dispatches one fixing agent per red repo in parallel (every `claude -p` pinned to `--model opus`, every agent spawned as opus), audits each round, merges its own fixes once `gh pr checks` is green (`land <pr>` where land knows the repo, else `gh pr merge --merge --delete-branch`) and watches main. A repo only she can unblock is PARKED and the run carries on with the rest. Rounds continue while they make progress (a red lane cleared or its failure signature changed); STUCK after 2 rounds without. **DONE is checked, not believed:** MAIN-GREEN only when every lane's latest run on main is green AND no fix PR of the sweep's is still open; a lane whose fix merged but has not re-run is FIXED-UNVERIFIED (never green, not re-worked) and is dispatched on main with `gh workflow run` and waited for (never for `how-we-know`). Work left at the 3h30 budget (done ~11:30; hard kill at 4h awake), or a lane it may not dispatch, ends MAIN-RED-UNFINISHED with the exact list carried to the next run (`state/fixed-unverified.tsv`, `state/unfinished-prs.tsv`, `carryover-next.md`). Every run leaves a ledger row, even one killed from outside (MAIN-RED-KILLED), and `latest.log` names the run in flight from its first line. This script never retries itself; a run that does not end green gets exactly one retry at 09:00, and a second non-green ending waits for the next Mon/Fri 08:00 run, briefed with what both tries did. Ends with one morning summary (green / fixed with PRs / parked with the decision needed / stuck): the log's last line and a macOS banner, always. Dry run: `CI_SWEEP_DRY_RUN=1 ~/bin/ci-sweep.sh`. Ledger: `~/Library/Logs/ci-sweep/state/outcomes.tsv`. |
| `ci-sweep-retry-if-red.sh` | Monday and Friday at 09:00 CT (`launchd/com.seq.ci-sweep-retry.plist`) | The retry gate. Reads today's rows in the ledger: already green today → no-op; today's only run so far was not green → runs `ci-sweep.sh` once more; already retried once today → no-op, waits for the next Mon/Fri 08:00 run. If the 08:00 run is still in flight (live lock holder) it waits for it — one bounded wait, to that run's own ceiling — and then decides from its row; a holder still alive past its ceiling is handed to `ci-sweep.sh`, whose lock reclaims it. |
| `ci-sweep-probe.sh` | (called) | Asks GitHub directly what main's state is. This, not any agent's report, decides whether the sweep is finished. A lane is only SILENT if `ci-sweep-triggers.py` says a commit in the window should have started it. |
| `ci-sweep-audit.sh` | (called) | Reads the diff of everything that landed and fails the sweep on `continue-on-error`, `xfail`, `skip`, `--no-verify`, `\|\| true`, `set +e` in added lines. Reaching green by weakening a check is the defect this whole system exists to prevent. Dual-use constructs (`if: always()`, a scoped `# noqa`, a caught exception) are judged on OUTCOME and are SUSPECT (exit 3, names the PR) rather than fatal. |
| `ci-sweep-triggers.py` | (called) | Answers "should this workflow have run", modelling `paths:`/`paths-ignore:`, branch filters, dispatch-only lanes, cron due-ness and job `if:` gates. Replaces a grep for `push:` that made healthy lanes permanently red. |
| `ci-sweep-selftest.sh` | (manual/CI) | Proves the two detectors above still detect, and that the docs cannot drift from the code: the primary plist fires exactly Monday and Friday at 08:00 (no other day, no other time), the retry plist fires exactly Monday and Friday at 09:00 and invokes `ci-sweep-retry-if-red.sh` (not `ci-sweep.sh` directly), this README/the script header/the prompt/the notifier/the gate state the days and both times and no daily phrasing survives, every `claude -p` carries `--model opus`, and none of the removed tick/window/retry knobs survive. Hard-fails on zero fixtures or zero workflows. |
| `ci-sweep-notify.sh` | (called) | The morning summary: a macOS banner after every run, green or not; a deduped GitHub issue per PARKED or STUCK repo naming the decision or credential needed, plus one run-level issue for TEMPFIX/HUNG/INTERRUPTED/could-not-run. A green run files nothing. |
| `ci-sweep-prompt.md` | — | The brief the sweep runs headlessly. Carries the incident history that shaped it. |
| `land` | (manual: `land [<pr>]`, `land --promote [<repo>] [--run-e2e]`) | Merge and deploy as ONE action. Verifies the PR's fast check itself, squash-merges, watches main's fast run to a terminal state (never the e2e run), then routes by repo (routes block). Self-deploying repos: confirms the Cloudflare build on the merge commit. A route with `STAGING` deploys staging from the merge sha at once (clean detached worktree, never the working tree). A route with `E2E_WF` deploys production only when a completed run of that workflow on the exact sha concluded success; otherwise it prints WAITING (exit 0). `--promote` ships the newest e2e-green main commit that is newer than what production runs, smoke-checks it and records it; `--run-e2e` dispatches the e2e workflow on main's head first and waits (ceiling 1.5x the last run). A repo whose `origin/main` has `.github/workflows/promote.yml` (sheila-creator-dashboard) promotes itself on a green e2e: `--promote` first waits for any in-flight promote run (ceiling 1.5x its last run, floor 6 min; past it: cancelled + NAMED STOP, exit 1) and reads production only after it — so it never deploys the same sha on top of that run; repos without promote.yml skip this silently. The production record is the GitHub Deployments API (environment `production`, one per land; `gh api repos/<r>/deployments?environment=production`). Routes without `E2E_WF` are unchanged: merge → production. A route with `E2E_WF` whose repo has a `deploy.yml` (boss-os) does not wait for a Deploy run after the merge — that workflow fires on the e2e run, not on CI — it prints WAITING. Rollout ledger for every seq23 repo: `docs/build-first-rollout-2026-09-26.md`. |
| `shorts-arm.sh` | — | YouTube shorts arming. |
| `schedule-inventory.sh` | — | What is scheduled on this machine. |
| `kdp-watch.sh` → | (symlink) | Lives in `boss-os/scripts/ops/`. Owned by Simone; chases Amazon KDP support to resolution. |

## Conventions these scripts hold to

- **Rule 0: no stage may exit 0 having done nothing.** Work done, or a named
  stop a human actually sees.
- **A guard that examines zero items must hard-fail**, never pass on an empty loop.
- **A legitimate stop is green, not red.** A lane correctly refusing to act —
  nothing queued, no credential, no new content — exits 0 and says why. It does
  not page her.
- **Bounds are enforced from outside the process.** A deadline the working
  process checks only bounds a process that is still working; a wedged one never
  reaches its own check. See the supervisor and sentry in `ci-sweep.sh`.
- **Two run days a week — Monday and Friday at 08:00 — one retry at 09:00, one answer.**
  The sweep runs Monday and Friday at 08:00 (owner's decision, 2 Oct 2026, first run Mon
  5 Oct; it was daily 07:00 from 24 Sep to 2 Oct) and keeps going while its rounds make
  progress; `ci-sweep.sh` itself never retries. If that run does not end green,
  `ci-sweep-retry-if-red.sh` (its own 09:00 plist, same two days) runs it again exactly
  once — never more than that on one run day. A second non-green ending is reported, not
  retried again, and the next Mon/Fri 08:00 run starts from its carryover (her design,
  23 Sep 2026; retry added on her instruction, 24 Sep 2026). Sleep is not a hang: the sentry measures its own heartbeat gaps and
  classes a run the Mac slept through as `MAIN-RED-INTERRUPTED`, with the round's
  open PRs parked, never merged or audited as landed work.
- **Pause:** write YYYY-MM-DD (last paused day) to `~/Library/Logs/ci-sweep/state/pause-until`; the sweep logs PAUSED rows and resumes itself on the first run day after it (owner's instruction, 26 Sep 2026; the 09:00 gate reads PAUSED as terminal).

## Installing the schedule

Two launchd jobs are versioned here: `launchd/com.seq.ci-sweep.plist` (Monday and
Friday 08:00, the sweep itself) and `launchd/com.seq.ci-sweep-retry.plist` (Monday and
Friday 09:00, the retry gate). Each carries two `StartCalendarInterval` entries, one per
weekday (launchd `Weekday` 1 = Monday, 5 = Friday).
After changing either:

```sh
cp ~/bin/launchd/com.seq.ci-sweep.plist ~/Library/LaunchAgents/
cp ~/bin/launchd/com.seq.ci-sweep-retry.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/com.seq.ci-sweep 2>/dev/null
launchctl bootout gui/$(id -u)/com.seq.ci-sweep-retry 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.seq.ci-sweep.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.seq.ci-sweep-retry.plist
launchctl print gui/$(id -u)/com.seq.ci-sweep | grep -A12 'event triggers'        # expect two entries: Weekday 1 and Weekday 5, each Hour 8, Minute 0
launchctl print gui/$(id -u)/com.seq.ci-sweep-retry | grep -A12 'event triggers'  # expect two entries: Weekday 1 and Weekday 5, each Hour 9, Minute 0
```

Never reload it while a sweep is running (`pgrep -f ci-sweep.sh`): bash reads a
script as it executes it.

## Validation

Until 2026-09-09 this repository had no CI of any kind — `gh workflow list`
returned nothing and no run had ever been recorded — while holding the scripts
that grade every other repository on this account. Nothing had ever checked that
`ci-sweep-audit.sh` so much as parses. A syntax error in the auditor is not a
loud failure; it is a sweep that passes everything.

`.github/workflows/validate.yml` closes that. It runs on every push and pull
request and it **deploys nothing and uses no secrets**, permanently:
`tests/validation-only.sh` reads the workflow files and fails if a credential
reference or a deploy step ever appears in one.

| Check | What it proves |
| --- | --- |
| `tests/lint-shell.sh` | Every `*.sh` parses (`bash -n`) and passes `shellcheck` at the warning gate. Hard-fails if it finds no scripts. |
| `tests/test-audit-guard.sh` | `ci-sweep-audit.sh` catches eight distinct weakenings in added lines, clears a genuine fix, and does not flag a diff that *removes* a weakening. |
| `tests/test-probe-convergence.sh` | `ci-sweep-probe.sh` maps lane states to the exit codes the convergence loop reads, and refuses an empty input set. |
| `tests/test-land-routes.sh` | `land`'s routes block (evaluated verbatim) resolves a real route to production for every West Peek site repo the web property change lane targets (westpeek-live, join-west-peek-main, west-peek-pitch-lab, west-peek-network-os, secondaries, founder-dilution-dashboard, west-peek-os, boss-os, …), and an unknown repo still stops. Build-first routes: sheila-creator-dashboard stages and waits for `e2e`; boss-os waits for `e2e` with no staging; a route with `E2E_WF` never takes the wait-for-Deploy-run branch; the three Pages repos' self-deploy sentences name staging and the e2e gate. Hard-fails on zero repos. |
| `tests/test-land-flow.sh` | `land` end to end against a fake `gh` and a real git origin (26 Sep 2026): a dirty checkout, a checkout on another branch and a clean main all land with her files and branch untouched (only a clean main is fast-forwarded); a scripted deploy runs from a throwaway worktree of `origin/main`; `~/bin` is fast-forwarded only around her edits or stops by name; a 401 on the head read never merges; a transient TLS error is retried (3 attempts) and lands; a persistent one exits 75 "could not verify (network)", never "not green"; a real failing check is still exit 1. `land --promote` against a repo with promote.yml waits for an in-flight promote run and then finds nothing to promote, stops by name (cancelling it) when it runs past the ceiling, skips the wait when there is no promote.yml, and after `--run-e2e` waits for the promote run the green e2e fires. Negative-proven by mutation, in-file for the promote wait. |
| `tests/test-land-plan.sh` | `land`'s plan block (evaluated verbatim): `land_plan` yields staging on every land, production only when the route has no e2e workflow or its run on the exact sha succeeded, WAITING otherwise, and `self` for self-deploying repos; `promote_pick` picks the newest e2e-green commit above production, never one below it, and nothing when production is already the newest green. Carries a negative proof (a plan that ships production without the verdict fails the test). |
| `tests/test-rule-zero.sh` | The validators above hard-fail on zero items, with positive and negative controls. |
| `tests/test-sweep-daily.sh` | `ci-sweep.sh` end to end against fake `claude`/`gh`/`land`/probe/audit: a parked repo does not end the run, rounds continue past two while they make progress and stop STUCK after two without, the sweep merges only PRs whose checks it read green (via `land` or `gh pr merge`), every `claude -p` carries `--model opus`, every run sends one banner and files issues only for parked/stuck repos, the script itself never self-retries (`ci-sweep.sh` names the 09:00 external retry gate, never an internal one), a heartbeat gap is INTERRUPTED (not HUNG), a TEMPFIX rejects the PR without merging or closing it, a merged-but-unrun lane is FIXED-UNVERIFIED (dispatched, or MAIN-RED-UNFINISHED), a green fix PR left open is never MAIN-GREEN and is resumed by the next run, and a killed supervisor still writes its row and ends its rounds. Carries three negative proofs. |
| `tests/test-retry-gate.sh` | `ci-sweep-retry-if-red.sh` against a fake ledger, lock and sweep: the ledger decides, an in-flight run is waited for and decided from its own row, a holder past its ceiling is handed to the sweep's reclaim. Carries a negative proof. |

Two of these carry an executed **negative proof**: they neutralise a rule in a
copy of the script under test and require the corresponding assertion to stop
passing. An assertion that cannot be made to fail is not evidence.

The probe's network path (`gh`, the GitHub API, lane classification) is **not**
covered — it needs live credentials, and a test that stubbed it would be
asserting the stub. Only the fixture path, which is the part the convergence
loop's exit code depends on, is verified.

Run the whole lane locally with:

```sh
for t in validation-only test-rule-zero lint-shell test-audit-guard test-probe-convergence; do
  ./tests/$t.sh
done
```

## The comments are the point

These files carry more comment than code, and it is deliberate: each guard
records the incident that produced it. Do not delete one without understanding
what it caught.

## The 2026-09-09 incident: a detector that matched strings

The 10:07 sweep aborted at 10:57 with `MAIN-RED-TEMPFIX`, filed west-peek-os#21
and threw away the morning's work, because the auditor found `if: always()` in
authority-backlink-network#99 — on a **reporting** step. Run 34371631703 ran on
b2e1790, the merge commit carrying that exact line, and still concluded
**failure**. It masks nothing; it makes the honest report print *on* failure,
which is the only reason that day's outage was visible at all.

At the same time the probe was reporting local-guides-generator's
`Build Starter Pack` as SILENT on every run. That workflow has a six-entry
`paths:` filter and the day's only commit touched `CHANGELOG.md` and two files
under `data/signals/`. **Not running was correct.**

Both were the same mistake — matching a string instead of testing an outcome —
and a false SILENT is the worse half, because it is *unclearable by
construction*: no work any agent can do makes a correctly-filtered workflow run,
so the loop cannot converge and spends the whole budget before ending red over a
healthy repo.

Two rules came out of it, and `ci-sweep-selftest.sh` enforces both:

- **Ask whether the outcome changed, not whether a string appears.** An
  `if: always()` on a step cannot turn a failing job green, and it is cleared
  outright by evidence that the workflow still concludes `failure`.
- **A false positive must not be able to abort a sweep doing real work.** Only an
  unambiguous weakening is fatal; anything unproven names its own pull request
  and the sweep carries on.
