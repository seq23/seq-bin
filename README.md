# ~/bin — scheduled machinery

Scripts that run unattended under `launchd` on this Mac. They exist because
some work cannot run in a Claude Code agent: **the agent runner strips every
environment variable matching `KEY|TOKEN|SECRET|PASSCODE`**, so anything that
needs the vault, the mailbox, Search Console or the `gh` login runs from here
instead.

Version controlled from 2026-09-08. Before that there was no history, and a bad
edit was recoverable only if someone had thought to copy the file first.

## Who does the work: `ai-run` (owner ruling, 3 Nov 2026)

> "after today we need to default OpenAI and Claude just be the brains"

From 4 Nov 2026 **OpenAI Codex does the hands-on work and Claude does only planning, deciding,
reviewing, summarising for her and company-brain writes.** Every scheduled job hands its prompt to
one runner, `~/bin/ai-run`, and names the role; nothing calls `claude -p` or `codex exec` directly.

    ai-run --role worker|brain [--cwd DIR] [--network] [--out FILE] -- "<prompt>"   # or the prompt on stdin

| Role | Engine | How |
|---|---|---|
| `worker` (fixing, building, landing) | Codex (the `codex` CLI on her ChatGPT plan) | `codex exec -s workspace-write`, stdin `</dev/null`, network only with `--network`, `--cwd` as its root. The `.git` of `--cwd`'s repo and of each repo directly under it are added as writable roots (workspace-write keeps `.git` read-only, so a worker could not commit). `AI_RUN_ADD_DIRS` adds a job's state directory. |
| `brain` (deciding, reviewing, summarising, brain writes) | Claude | `claude -p --model opus --dangerously-skip-permissions`, prompt on stdin. `AI_RUN_CLAUDE_ARGS` replaces the permission flag for a job that needs other flags (pnp-listings: Claude in Chrome only). |

- **A Codex usage limit hands the run to Claude** (her fallback chain, 6 Nov 2026: Gemini free → OpenRouter free → Codex → Claude → a named stop, never waiting for a reset while a later step can run). Only with `AI_RUN_NO_CLAUDE_FALLBACK=1` does it still exit **75** `NAMED STOP [CODEX_LIMIT] resets <time>`, which each caller turns into its own named wait. ci-sweep also hands a CODEX_UNAVAILABLE round to Claude; Claude out too is `CLAUDE_UNAVAILABLE` / `CLAUDE_LIMIT`, MAIN-RED-UNFINISHED with the carryover.
- **Codex missing, logged out, or logged in with an API key** (which bills per token — there is no paid OpenAI API, that is money) is `NAMED STOP [CODEX_UNAVAILABLE]`, exit 69.
- **`--out FILE`** is appended to as the engine prints, so a run a cap kills still leaves its transcript; a kill sent to `ai-run` reaches the engine. Without `--out`, the output is printed when the run ends.
- **Every run appends one line** to `~/Library/Logs/ai-run.log`: time, role, engine, caller, exit (and the stop, if any).
- **`AI_RUN_WORKER=claude`** runs the worker role on Claude. Besides her manual use, only the partner tail (`scooter-watch-run-fix.sh`) and ci-sweep's Codex-out hand-off set it; `tests/test-ai-run.sh` fails if any other tracked file does.
- **The interface is shared**: boss-os and west-peek-os call `~/bin/ai-run` with exactly these flags. Change them only in all three repos together.
- **Sentinels are read at line start.** `codex exec` echoes its prompt into the log, and a prompt's sentinel templates are indented, so `grep '^SENTINEL:'` never mistakes the echo for a result.

| Caller | Role | Why |
|---|---|---|
| `ci-sweep.sh` | worker (`--cwd ~/GitHub --network`) | Fixes red CI; one Codex run per round, the repos one at a time. |
| `scooter-watch.sh` → `scooter-watch-run-fix.sh` | worker (`--cwd west-peek-os --network`) | Root-causes and fixes partner friction. |
| `shorts-arm.sh` | worker, then brain | Codex arms the lane; Claude emails her the result (her Gmail is a claude.ai connector Codex cannot reach). |
| `pnp-listings.sh` | brain — **named exception** | Drives her own Chrome through Claude in Chrome, which only Claude can reach. |
| `handoff-on-compact.sh` | (not ai-run) | A Claude Code hook, so it stays on Claude. |

## What's here

| Script | Schedule | What it does |
|---|---|---|
| `ai-run` | (called) | The one runner every scheduled job uses: `--role worker` → Codex, `--role brain` → Claude; a Codex usage limit hands the run to Claude (exit 75 `CODEX_LIMIT` only with the hand-off switched off). See the section above. |
| `ci-sweep.sh` | Monday and Friday at 08:00 CT (`launchd/com.seq.ci-sweep.plist`; owner's decision 2 Oct 2026, first run Mon 5 Oct), with one retry at 09:00 the same day if not green (`launchd/com.seq.ci-sweep-retry.plist` → `ci-sweep-retry-if-red.sh`) | Goal: every repo's main green. Probes the fleet, runs one Codex worker per round (`ai-run --role worker --cwd ~/GitHub --network`), which works the red repos one at a time; Codex out (usage limit or unavailable) hands the same brief to Claude for the rest of the run, same caps and budget; Claude out too ends the run MAIN-RED-UNFINISHED (named CLAUDE_LIMIT / CLAUDE_UNAVAILABLE, carried to the next run). It audits each round, merges its own fixes once `gh pr checks` is green (`land <pr>` where land knows the repo, else `gh pr merge --merge --delete-branch`) and watches main. A repo only she can unblock is PARKED and the run carries on with the rest. Rounds continue while they make progress (a red lane cleared or its failure signature changed); STUCK after 2 rounds without. **DONE is checked, not believed:** MAIN-GREEN only when every lane's latest run on main is green AND no fix PR of the sweep's is still open; a lane whose fix merged but has not re-run is FIXED-UNVERIFIED (never green, not re-worked) and is dispatched on main with `gh workflow run` and waited for (never for `how-we-know`). Work left at the 3h30 budget (done ~11:30; hard kill at 4h awake), or a lane it may not dispatch, ends MAIN-RED-UNFINISHED with the exact list carried to the next run (`state/fixed-unverified.tsv`, `state/unfinished-prs.tsv`, `carryover-next.md`). A run the Mac slept through (MAIN-RED-INTERRUPTED) is resumed on wake by `ci-sweep-resume-on-wake.sh` as the same attempt while its budget has room. Every run leaves a ledger row, even one killed from outside (MAIN-RED-KILLED), and `latest.log` names the run in flight from its first line. This script never retries itself; a run that does not end green gets exactly one retry at 09:00, and a second non-green ending waits for the next Mon/Fri 08:00 run, briefed with what both tries did. Ends with one morning summary (green / fixed with PRs / parked with the decision needed / stuck): the log's last line and a macOS banner, always. Dry run: `CI_SWEEP_DRY_RUN=1 ~/bin/ci-sweep.sh`. Ledger: `~/Library/Logs/ci-sweep/state/outcomes.tsv`. |
| `ci-sweep-retry-if-red.sh` | Monday and Friday at 09:00 CT (`launchd/com.seq.ci-sweep-retry.plist`) | The retry gate. Reads today's rows in the ledger: already green today → no-op; today's only run so far was not green → runs `ci-sweep.sh` once more; already retried once today → no-op, waits for the next Mon/Fri 08:00 run. If the 08:00 run is still in flight (live lock holder) it waits for it — one bounded wait, to that run's own ceiling — and then decides from its row; a holder still alive past its ceiling is handed to `ci-sweep.sh`, whose lock reclaims it. |
| `ci-sweep-resume-on-wake.sh` | Every 300 s (`launchd/com.seq.ci-sweep-resume.plist`; owner, 12 Oct 2026: "just pick up where it left off if I close the lid and then re-open") | Resume on wake. If today's latest sweep run ended `MAIN-RED-INTERRUPTED` (the Mac slept mid-run), no sweep is running, at least 20 minutes are left before that run's stop-by time and its 240-awake-minute ceiling has room, it starts `ci-sweep.sh` again as a RESUME of that run: same stop-by, the awake minutes already spent counted against the hard kill, the PRs it merged and lanes it dispatched, and the SAME ledger row (replaced, with `resumed-by=<run-id>` as a fifth column) so the 09:00 retry still sees one attempt. Anything else (KILLED, HUNG, green, past stop-by, a sweep running) is a no-op: one line in `~/Library/Logs/ci-sweep/resume.log` (last 1000 lines kept), in under a second. Dry run: `CI_SWEEP_RESUME_DRY_RUN=1 ~/bin/ci-sweep-resume-on-wake.sh`. |
| `ci-sweep-probe.sh` | (called) | Asks GitHub directly what main's state is. This, not any agent's report, decides whether the sweep is finished. A lane is only SILENT if `ci-sweep-triggers.py` says a commit in the window should have started it. |
| `ci-sweep-audit.sh` | (called) | Reads the diff of everything that landed and fails the sweep on `continue-on-error`, `xfail`, `skip`, `--no-verify`, `\|\| true`, `set +e` in added lines. Reaching green by weakening a check is the defect this whole system exists to prevent. Dual-use constructs (`if: always()`, a scoped `# noqa`, a caught exception) are judged on OUTCOME and are SUSPECT (exit 3, names the PR) rather than fatal. |
| `ci-sweep-triggers.py` | (called) | Answers "should this workflow have run", modelling `paths:`/`paths-ignore:`, branch filters, dispatch-only lanes, cron due-ness and job `if:` gates. Replaces a grep for `push:` that made healthy lanes permanently red. |
| `ci-sweep-selftest.sh` | (manual/CI) | Proves the two detectors above still detect, and that the docs cannot drift from the code: the primary plist fires exactly Monday and Friday at 08:00 (no other day, no other time), the retry plist fires exactly Monday and Friday at 09:00 and invokes `ci-sweep-retry-if-red.sh` (not `ci-sweep.sh` directly), the resume plist is `com.seq.ci-sweep-resume` every 300 s running `ci-sweep-resume-on-wake.sh` and nothing else (and this README, the sweep, the gate and the resume script name it), this README/the script header/the prompt/the notifier/the gate state the days and both times and no daily phrasing survives, every round runs `ai-run --role worker` and no `claude -p` remains, and none of the removed tick/window/retry knobs survive. Hard-fails on zero fixtures or zero workflows. |
| `ci-sweep-notify.sh` | (called) | The morning summary: a macOS banner after every run, green or not; a deduped GitHub issue per PARKED or STUCK repo naming the decision or credential needed, plus one run-level issue for TEMPFIX/HUNG/INTERRUPTED/could-not-run. A green run files nothing. |
| `ci-sweep-prompt.md` | — | The brief the sweep runs headlessly. Carries the incident history that shaped it. |
| `land` | (manual: `land [<pr>]`, `land --promote [<repo>] [--run-e2e]`) | Merge and deploy as ONE action. **Checks still running are not green: land refuses a PR whose checks are pending** (and one whose checks have not shown up yet), so a background command runs `gh pr checks <pr> --watch` first, then `land <pr>`. Verifies the PR's fast check itself, squash-merges, watches main's fast run to a terminal state (never the e2e run; the run watched is the workflow `deploy.yml` gates on, else the workflow that ran the PR's own checks, else the newest — 2 Oct 2026: with no `deploy.yml`, `[0]` was a 20-second recovery run and a cancelled Validate Repo read as green), then routes by repo (routes block). Self-deploying repos: confirms the Cloudflare build on the merge commit; a Pages project whose build watch paths no changed file reaches, and that posted nothing, is "no deploy needed" (3 Nov 2026, heygetonmylevel #12; unreadable paths fail closed, a build that started and failed still stops). A route with `STAGING` deploys staging from the merge sha at once (clean detached worktree, never the working tree). A route with `E2E_WF` deploys production at once when a completed run of that workflow on the exact sha concluded success; otherwise it measures the PR (the `large` block — the ONE definition of "large", which the repos point at rather than restate: ≥ 200 lines, ≥ 8 files, any migration / e2e spec / Playwright config change, or a UI-surface file with ≥ 40 lines; `LAND_LARGE_LINES`, `LAND_LARGE_FILES`, `LAND_LARGE_UI_LINES` override) and every other commit main carries past production's recorded sha (the `range` block: each judged by the same rule; production unreadable or not an ancestor = large). For a LARGE change it dispatches the e2e workflow on main itself, waits (ceiling 1.5x the last run, floor 10 min), and ships production only on green — printing why and recording the reason on the GitHub Deployment; a red run is `NAMED STOP [E2E_RED_AFTER_LARGE_CHANGE]`, production untouched. **A SMALL change ships to production on the fast check alone** (owner, 2 Oct 2026: the e2e workflows are dispatch-only, never scheduled, and a small change no longer prints WAITING for a suite nothing would run) — printed and recorded as "small change: N lines, M files; shipped on the fast check, e2e on demand". **Known red blocks it:** the newest e2e run on main that reached a verdict (cancelled/skipped runs are passed over) must be `success`, or there must be none; otherwise `NAMED STOP [E2E_KNOWN_RED]`, staging runs the sha, production untouched, and `land <pr> --run-e2e` ships it on a green suite. A red run on the exact sha blocks likewise; an unreadable history is exit 75, never "not red". `land <pr> --run-e2e` forces the suite for any size. Landing a merged PR again never rolls production back and never deploys the sha it already runs. A self-deploying repo whose production moves through its own workflow (`PROMOTE_VIA`: secondaries, founder-dilution-dashboard → `promote.yml`; justbeingmercedes → `deploy.yml`) follows the same plan: land confirms the staging build, then dispatches that workflow with `-f sha=` and `-f reason=`, waits for the run (ceiling 1.5x, floor 6 min) and reads the GitHub Deployment back. `--promote` ships the newest e2e-green main commit that is newer than what production runs, smoke-checks it and records it; `--run-e2e` dispatches the e2e workflow on main's head first and waits (ceiling 1.5x the last run). A repo whose `origin/main` has `.github/workflows/promote.yml` (sheila-creator-dashboard) promotes itself on a green e2e: `--promote` first waits for any in-flight promote run (ceiling 1.5x its last run, floor 6 min; past it: cancelled + NAMED STOP, exit 1) and reads production only after it — so it never deploys the same sha on top of that run; repos without promote.yml skip this silently. The production record is the GitHub Deployments API (environment `production`, one per land; `gh api repos/<r>/deployments?environment=production`). Routes without `E2E_WF` are unchanged: merge → production. A route with `E2E_WF` whose repo has a `deploy.yml` (boss-os) does not wait for a Deploy run after the merge — that workflow fires on the e2e run, not on CI; a small change is deployed from the laptop, and after a green suite land waits for that `deploy.yml` run (`PROMOTE_WF`) instead of racing it. Rollout ledger for every seq23 repo: `docs/build-first-rollout-2026-09-26.md`. |
| `housekeeping.sh` | Daily 03:30 CT (`launchd/com.seq.housekeeping.plist`), after the 01:40 CT backup | Nightly checks that post to Boss OS Open Loops (repo `seq23/seq-bin`, upserted by stop code; a clean result closes the row): unsaved edits older than 24 h in any checkout (`UNSAVED_<path>`, one row per checkout; never commits, stashes or discards; a `~/GitHub/.wt-*` worktree changed in the last 24 h is a running agent's and is left alone), a folder the backup held back (`BACKUP_BIG_FOLDER`, hers to decide) or a backup stop in today's log (`BACKUP_TOO_SLOW` / `BACKUP_FAILED` / `BACKUP_DID_NOT_RUN`), and a monthly rules clean-up (`RULES_CLEANUP_YYYY_MM`: the 1st, or `~/.claude/CLAUDE.md` over 2,000 words; posted once a month). Token from the Boss OS vault at run time. A failed post is `NAMED STOP [OPEN_LOOPS_POST_FAILED]`, exit 9. Dry run: `HOUSEKEEPING_DRY_RUN=1 ~/bin/housekeeping.sh`. Test: `tests/test-housekeeping.sh`. |
| `mac-snapshot.sh` | 1st and 15th at 10:00 CT (`launchd/com.seq.mac-snapshot.plist`, her rulings 8 Nov 2026); manual `--now`, size check `--measure` | One AES-256 encrypted disk image (`hdiutil`, passphrase from the Keychain item `mac-snapshot`/`sequoia`) of everything only on this Mac, including the Boss OS vault and its master key, to sequoialtaylor's Drive (rclone `gdrive-sl`, folder Mac-Snapshots, newest 2 kept). Verified by opening it read-only and matching staging file for file and byte for byte before upload; Drive size confirmed after. Only irreplaceable media sources; rendered videos, venvs and models are left out (the image's README-RESTORE.txt says where the models come from, and how to restore). Result or named stop to her as a banner plus the Open Loops row `MAC_SNAPSHOT`. The nightly `drive-backup.sh` (seq.taylor's Drive, 01:40 CT) stays small and holds nothing private. Test: `tests/test-mac-snapshot.sh`. |
| `tz-watch.sh` | When `/etc/localtime` changes, at login and hourly (`launchd/com.seq.tz-watch.plist`, 1 Nov 2026) | Keeps every job on its Central time when the Mac changes zone. Every job is written in Central and each installer moves the hours to the Mac's zone (boss-os `scripts/ops/plist-central.mjs`, the one mover), but only at install time. This compares the Central-to-local offset with the one each installer last ran for (`~/Library/Application Support/tz-watch/`) and re-runs only the installers that are off: `install-launchd.sh` (every label but its own), boss-os `install-agent-launchd.sh` from the runtime checkout, how-we-know `loop-install-launchd.sh --install`. Same offset = a one-line no-op. A scheduled job mid-run is not killed (`TZ_WATCH_DEFERRED`, retried hourly, up to 6 h). A failing installer is `NAMED STOP [TZ_WATCH_INSTALL_FAILED]` plus an Open Loops row (via `open-loops.mjs`, token from the vault), closed by the next success. Log: `~/Library/Logs/tz-watch.log`. Test: `tests/test-tz-watch.sh`. |
| `open-loops.mjs` | (called) | The one poster to Boss OS Open Loops (`housekeeping.mjs`, `tz-watch.sh`). |
| `shorts-arm.sh` | Daily 10:11 (`launchd/com.seq.shorts-arm.plist`) | YouTube shorts arming: a Codex worker in `how-we-know`, then a Claude brain run emails her the result. |
| `schedule-inventory.sh` | — | Retired 1 Nov 2026: the schedule is the Boss OS Schedule page (☰ More → Schedule); this prints where and exits 3. |
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
  open PRs parked, never merged or audited as landed work. **An interrupted run picks up
  where it left off** (owner, 12 Oct 2026): `ci-sweep-resume-on-wake.sh`, every 300 s
  under `com.seq.ci-sweep-resume`, resumes it on the first tick after wake while its
  budget has room — same stop-by, same awake ceiling, same session, same ledger row. If
  the resumed run is still in flight at 09:00, the retry gate waits for it.
- **Pause:** write YYYY-MM-DD (last paused day) to `~/Library/Logs/ci-sweep/state/pause-until`; the sweep logs PAUSED rows and resumes itself on the first run day after it (owner's instruction, 26 Sep 2026; the 09:00 gate reads PAUSED as terminal).

## Installing the schedule

Every launchd job versioned here is in `launchd/`, with its hours written in **Central** time:
the CI sweep (Monday and Friday 08:00), its retry (Monday and Friday 09:00), resume on wake (every
300 s), Scooter watch (every 15 min) and its digest (Monday 07:00, retry 08:00), the Shorts check
(daily 10:11), dev housekeeping (the 1st and 15th, 10:30) and the P&P Marketplace listings (daily
13:40). Her Mac runs on Eastern, and launchd reads Hour in the Mac's zone, so a copied plist fires
an hour early (it did until 1 Nov 2026). Install with:

```sh
~/bin/install-launchd.sh             # every job: copy, move to the Mac's zone, lint, reload
~/bin/install-launchd.sh com.seq.ci-sweep com.seq.ci-sweep-retry   # just these
launchctl print gui/$(id -u)/com.seq.ci-sweep | grep -A12 'event triggers'   # on an Eastern Mac: Weekday 1 and 5, Hour 9 (= 08:00 Central)
```

It uses boss-os `scripts/ops/plist-central.mjs`, the same mover Boss OS's own installer uses.
`tests/test-launchd-central.sh` proves it. Boss OS's Schedule page lists every job here.

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
| `tests/test-probe-window.sh` | `ci-sweep-probe.sh`'s network path, against a fake `gh`: a lane missing from the repo-wide newest-80 run list is asked for its own newest run (GREEN, not SILENT), a lane that truly never ran is still SILENT\|NEVER_RAN, and an unreadable per-lane list is PENDING. |
| `tests/test-land-routes.sh` | `land`'s routes block (evaluated verbatim) resolves a real route to production for every West Peek site repo the web property change lane targets (westpeek-live, join-west-peek-main, west-peek-pitch-lab, west-peek-network-os, secondaries, founder-dilution-dashboard, west-peek-os, boss-os, …), and an unknown repo still stops. Build-first routes: sheila-creator-dashboard stages and waits for `e2e`; boss-os waits for `e2e` with no staging; a route with `E2E_WF` never takes the wait-for-Deploy-run branch; the three Pages repos' self-deploy sentences name staging and the e2e gate. Hard-fails on zero repos. |
| `tests/test-land-flow.sh` | `land` end to end against a fake `gh` and a real git origin (26 Sep 2026): a dirty checkout, a checkout on another branch and a clean main all land with her files and branch untouched (only a clean main is fast-forwarded); a scripted deploy runs from a throwaway worktree of `origin/main`; `~/bin` is fast-forwarded only around her edits or stops by name; a 401 on the head read never merges; a transient TLS error is retried (3 attempts) and lands; a persistent one exits 75 "could not verify (network)", never "not green"; a real failing check is still exit 1. `land --promote` against a repo with promote.yml waits for an in-flight promote run and then finds nothing to promote, stops by name (cancelling it) when it runs past the ceiling, skips the wait when there is no promote.yml, and after `--run-e2e` waits for the promote run the green e2e fires. A large PR on an e2e route runs the suite and lands when its promote.yml ships the green sha, `--run-e2e` forces it, a red suite is a NAMED STOP with production untouched, and an unreadable PR size is treated as large. 2 Oct 2026 (small changes ship on the fast check): a small PR deploys staging AND production from the merge sha and records the reason; a suite known red on main, or red on the exact sha, is `NAMED STOP [E2E_KNOWN_RED]` with production untouched and `--run-e2e` as the way out; an unreadable e2e history is exit 75; a large commit production has not seen makes land run the suite behind a small PR; unreadable production is large; a merged PR production already runs (or has passed) deploys nothing; `PROMOTE_VIA` repos are shipped by dispatching their own workflow with the sha and reason (red run, or a green run with no record: not LANDED); boss-os waits for `deploy.yml` after a green suite. Negative-proven by mutation, in-file: no promote wait, shipping past red, judging only the PR, the boss-os race. |
| `tests/test-land-large.sh` | `land`'s large block (evaluated verbatim): every threshold at its edge (199/200 lines, 7/8 files, 39/40 UI lines), every path trigger (migrations, e2e specs, Playwright configs, `client/`, `app/`, `public/`, `functions/`, `routes/`, `.html`), the env overrides, and unreadable = large. Carries a negative proof (a block that never calls a change large fails the test). |
| `tests/test-land-d1.sh` | `land`'s routes and d1 blocks (evaluated verbatim) against a fake `npx` (30 Oct 2026, p-n-p #162: Pages shipped code needing migration 0026 and nothing applied it): p-n-p names D1 `pnp-admin`; a PR that adds a migration (or whose paths cannot be read) gets `CI=true npx wrangler d1 migrations apply pnp-admin --remote` from its head BEFORE `gh pr merge`, read back with `migrations list`; a failed apply, or one that leaves anything pending, is `NAMED STOP [D1_MIGRATION_FAILED]` with nothing merged; after the merge any migration still owed is applied and an unreadable or non-empty pending list is `NAMED STOP [D1_MIGRATIONS_PENDING]`, never LANDED. Pins both call sites' order in land. Negative proofs: a block that trusts the apply without reading the list back, one that skips the pre-merge apply, and (by hand) a land without either call. |
| `tests/test-land-plan.sh` | `land`'s plan block (evaluated verbatim): `land_plan` yields staging on every land; production when the route has no e2e workflow, when its run on the exact sha succeeded, or when the change is small and the suite's last verdict on main is green or absent; `suite` for a large change or `--run-e2e`; `blocked` when a small change meets a known-red suite, a red run on its own sha, or a verdict that could not be read (the four pins that used to say WAITING now say blocked, fail closed); and `self` for self-deploying repos. `e2e_last_verdict` (the `verdict` block, through real jq) passes over cancelled, skipped and in-flight runs. `promote_pick` picks the newest e2e-green commit above production, never one below it, and nothing when production is already the newest green. Five negative proofs: a plan that ships a large change without the suite, past a known red, on an unread verdict, or past a red on the exact sha, and a verdict filter that keeps cancelled runs. |
| `tests/test-rule-zero.sh` | The validators above hard-fail on zero items, with positive and negative controls. |
| `tests/test-mac-snapshot.sh` | macOS only. `mac-snapshot.sh` against a fake home, a stub Keychain and a local "Drive": both one-time stops name her line; a staging change after the image is built is refused by the verify step and nothing is uploaded; a wrong passphrase does not open the image, the right one restores it byte-identical; newest 2 kept; the key and passphrase never appear in the log or stdout. |
| `tests/test-ai-run.sh` | `ai-run` against stub `codex` and `claude` on PATH: the worker runs `codex exec -s workspace-write` with stdin `/dev/null` and never claude (network only with `--network`, the repo's `.git` writable); a usage-limit message is exit 75 and `CODEX_LIMIT resets <time>` with no claude call, while a run that merely printed one and finished is not; codex missing, logged out or on an API key is `CODEX_UNAVAILABLE`; the brain runs `claude -p --model opus` and never codex; `--out` appends, keeps what was printed before a kill, and the kill reaches codex; every run logs one line; no tracked job sets `AI_RUN_WORKER`. |
| `tests/test-sweep-daily.sh` | `ci-sweep.sh` end to end through the real `ai-run` against fake `codex`/`claude`/`gh`/`land`/probe/audit: a parked repo does not end the run, rounds continue past two while they make progress and stop STUCK after two without, the sweep merges only PRs whose checks it read green (via `land` or `gh pr merge`), every round runs `ai-run --role worker` and no `claude -p` remains, every run sends one banner and files issues only for parked/stuck repos, the script itself never self-retries (`ci-sweep.sh` names the 09:00 external retry gate, never an internal one), a heartbeat gap is INTERRUPTED (not HUNG) and the real resume script picks it up as the same attempt (same row, same stop-by, the merges and dispatches it carried), a TEMPFIX rejects the PR without merging or closing it, a merged-but-unrun lane is FIXED-UNVERIFIED (dispatched, or MAIN-RED-UNFINISHED), a green fix PR left open is never MAIN-GREEN and is resumed by the next run, and a killed supervisor still writes its row and ends its rounds. Carries three negative proofs. |
| `tests/test-resume-on-wake.sh` | `ci-sweep-resume-on-wake.sh` against a fake ledger, lock and sweep: an INTERRUPTED row with budget left is resumed as the same attempt (ledger id, stop-by, awake time carried, chained resumes from the latest attempt); a running sweep, a passed stop-by, a spent ceiling, a KILLED or GREEN latest row are refused; `resume.log` stays bounded. Carries a negative proof. The resumed run itself is scenario 8a of `tests/test-sweep-daily.sh`. |
| `tests/test-retry-gate.sh` | `ci-sweep-retry-if-red.sh` against a fake ledger, lock and sweep: the ledger decides, an in-flight run is waited for and decided from its own row, a holder past its ceiling is handed to the sweep's reclaim. Carries a negative proof. |

Two of these carry an executed **negative proof**: they neutralise a rule in a
copy of the script under test and require the corresponding assertion to stop
passing. An assertion that cannot be made to fail is not evidence.

The probe's network path (`gh`, the GitHub API, lane classification) is covered
only by `tests/test-probe-window.sh`, against a fake `gh`, for the never-ran
decision; the rest of it needs live credentials. The fixture path, which the
convergence loop's exit code depends on, is verified by test-probe-convergence.

Run the whole lane locally with:

```sh
for t in validation-only test-rule-zero lint-shell test-audit-guard test-probe-convergence test-probe-window; do
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
