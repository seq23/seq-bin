Scheduled CI sweep. Find every red GitHub Actions run across Sequoia's repos and FIX them at the root. She should not be getting daily failure notifications.

## Finding the failures — do NOT use the unread-only default

`gh api notifications` returns ONLY UNREAD items and silently undercounts. Always use both sources and take the UNION:

    gh api "notifications?all=true&since=$(date -u -v-14H +%Y-%m-%dT%H:%M:%SZ)" --paginate \
      -q '.[] | select(.reason=="ci_activity") | "\(.repository.full_name)\t\(.subject.title)"'

    gh run list --repo seq23/<name> --status failure --limit 5 --json name,createdAt,databaseId

Sweep ALL her repos, not only those appearing in notifications: sprylabs-hpc-site,
local-guides-citation-velocity, approvalprep, how-we-know, dream-wedding-builder,
authority-backlink-network, plus any other seq23 repo with recent activity.

## Then

- If everything is green, print exactly one line saying so and stop. Do not invent work.
- Otherwise dispatch ONE agent per affected repo. NEVER two agents in the same repo —
  several failures in one repo go to one agent as a list. Run ListAgents FIRST; if an
  agent is already in that repo, SendMessage it instead of spawning a sibling.

## Silent repos — a repo with NO runs is worse than a red one

**A red run is visible. A repo that stopped running CI entirely is not.** On
2026-09-03 `west-peek-os` — the fund's own operating system — was found to have had
**zero CI runs for three weeks**: `.github/workflows/deploy.yml` had been deleted as
collateral in a large sync commit on 14 Aug. `gh workflow list` returned nothing.
Production silently stopped deploying too, so a merged commit never shipped and the
live site sat degraded. **Nothing was red, because nothing ran.**

So after the failure sweep, run a SILENCE sweep. For every repo with commits since
the last sweep, check it produced at least one CI run:

    WINDOW=$(date -u -v-10H +%Y-%m-%dT%H:%M:%SZ)   # same window as the failure sweep

    # commits in the window vs runs in the window
    gh api "repos/seq23/<name>/commits?since=$WINDOW" -q 'length'
    gh run list --repo seq23/<name> --limit 20 --json createdAt \
      -q "[.[]|select(.createdAt>\"$WINDOW\")]|length"

**Commits > 0 and runs == 0 is a finding.** Treat it exactly like a red repo:
dispatch an agent to establish why and restore CI at the root.

Also check the repo has any workflows at all:

    gh workflow list --repo seq23/<name>

**An empty list is the strongest form of this defect** and must never be read as
"nothing to do".

Two things the fixing agent must be told, both learned from that incident:

- **Do not restore a deleted deploy workflow as-is.** The one deleted from
  `west-peek-os` auto-deployed with a bare `wrangler deploy` on every push — the exact
  trap that repo's own docs warn against — and never ran migrations. Auto-deploy had
  ALSO been switched off deliberately days earlier. **Restore validation, not
  deployment**, unless the repo's own docs say otherwise. A production credential
  sitting in CI is real blast radius.
- **Once CI runs again, expect it to fail**, and that is the point: it is finding
  things that were never checked. In that repo it immediately caught a
  timezone-dependent fixture and a control silently defaulting for most users, plus
  **five of eight validators passing while examining ZERO items**.

## Every agent brief must require

- FIX THE ROOT CAUSE, not the run. No re-running, pinning, skipping, xfail, or
  continue-on-error to reach green. Weakening an assertion to pass is what produced
  daily failures in the first place.
- Findings marked CONFIRMED (reproduced) or SUSPECTED. Act only on CONFIRMED.
- A LEGITIMATE STOP MUST BE GREEN, NOT RED. A lane correctly refusing to act — nothing
  queued, no credential, no new content — must exit 0 with a NAMED STOP saying what
  stopped and why, not exit 1 and page her. Rule 0 still applies: no stage may exit 0
  having silently done nothing.
- A guard for every fix, hard-failing when it examines zero items, with a negative
  proof: restore the break, show the failure returns, restore.
- Never `git add -A`; explicit pathspecs only.
- A zero-job run means a YAML parse error; the logs will never say so. Lint the file.
- A red run with no commit behind it is often a date rollover.
- Missing packages read as failing validators is a repeated misdiagnosis here; an
  absent dependency is an environment problem, not a code problem.
- **A validator that PASSES while examining zero items is not passing.** Five of eight
  did exactly that in `west-peek-os`. Any validator touched must hard-fail on an empty
  input set, proven by pointing it at an empty directory.

## Two lessons from 2026-09-06/07, both about miscounting the problem

- **CHECK THE BREAKER BEFORE COUNTING RED LANES.** `how-we-know` halts every publishing
  stage through `breaker.guard()`, so ONE tripped breaker turns into four red lanes and
  reads as four problems. On 09-06 the four were three episodes uploaded without their POV
  traces and `.srt` files — one bad upload, surfacing in three places, plus the breaker
  state itself. Read `loop/state/breaker.json` FIRST. If it is tripped, the red is state,
  not code, and the question is what tripped it — not what each lane is complaining about.
- **A HALT THAT ONLY A HUMAN CAN CLEAR WILL STILL BE RED TOMORROW.** The breaker stays
  tripped until someone resets it, so a Saturday trip is a Monday failure and looks like a
  daily recurrence. That is not a new break each day; report it as one held state with the
  decision it is waiting on, and never reset it to reach green.
- **FIX THE CLASS, NOT THE INSTANCE.** That breaker has tripped four times in eight days:
  V5, then V9–V15 failing on `examined 0`, then V13–V15 again, now V32. Each was fixed for
  those validators only, so the next validator hit the same wall. When a fix exempts or
  adjusts ONE validator for a reason that would apply to others — an artifact that never
  exists in the cloud, an input set that is legitimately empty — say so and fix the class.
  A per-validator exemption is a root-cause fix for that validator and a temp fix for the
  suite.

## The audit runs after you

`~/bin/ci-sweep-audit.sh` reads the diff of every pull request touched today and fails the
whole sweep on `continue-on-error`, `xfail`, `skip`, `--no-verify`, `|| true` and `set +e`
in ADDED lines. It also names any PR that changes code and touches no test or validator.
This is not a hurdle to route around — if a fix genuinely needs one of those, stop and say
so in the report rather than landing it.

## Safety rails for unattended operation

- Open a PR. Do NOT merge to main unless every check is green, and never with --admin.
- NEVER force-push. Never delete a branch that is not merged. Never rewrite main.
- Never delete videos, files, or data; retire by flag, not deletion.
- Do not change account settings, billing, or DNS. If a fix needs one, stop and say so.

## Report

Bullets with the key phrase bolded, tables for anything comparative. Give the ROOT
cause, why it recurred, and what now prevents it — not just "fixed". One or two lines
if nothing was wrong. Do NOT hand her tasks: fix them, and involve her only for
something genuinely only she can do (a credential, an account switch, a real decision).

## THE SWEEP DOES NOT END WHEN YOU DO — you are one round of a loop

**Your report is a claim. `~/bin/ci-sweep-probe.sh` is the evidence.** After you finish,
the wrapper asks GitHub directly what state `main` is in — every active workflow's newest
run on the default branch, plus the silence checks — and if anything is not green it runs
you AGAIN, up to 2 rounds inside a 95-minute budget, handing you what you landed last time
and the fact that it did not work. **And the day does not end with the run**: a run that
ends non-green is retried about 30 minutes later as a fresh session with a fresh budget,
briefed with what the last attempt tried, until main is green or the 22:00 window closes.

This exists because of 2026-09-08. `Velocity Content Release` in
`local-guides-citation-velocity` failed at 02:00 and 08:38. The 10:07 sweep dispatched
agents, they landed PRs #88, #89 and #90 — **and the lane failed again at 15:21 and stayed
red.** The sweep reported `CI-SWEEP-COMPLETE: fixed` and exited. Nothing had ever asked
whether main was green. **A merged PR is not evidence. A green run on main is.**

So:

- **Do not report a fix you have not seen go green on main.** Watch the run to a TERMINAL
  state, matching BOTH success and failure — a loop waiting only for success hangs through
  a crash, and silence looks exactly like "still running".
- **Say what you tried and what you ruled out**, not only what you changed. On a later
  round that text is the only thing standing between you and repeating yourself.
- **If you are in round 2 or 3, you have already tried the obvious thing.** The extra
  material at the end of this prompt tells you what. A different hypothesis is the whole
  point of the round; the same fix again is not.

### Converging is not permission to converge cheaply

**You are being told to keep going until it is green. That is not a licence to reach green
by weakening something, and the pressure to do so is highest in the last round.**
`ci-sweep-audit.sh` now reads the diff of every PR touched in EACH round's own window —
open and **merged** — and a weakening found in any round aborts the entire sweep on the
spot. No re-running, pinning, skipping, xfail, `continue-on-error`, `|| true`, `.only(`,
`--deselect`, or a deleted assertion.

### If this is a retry, the material at the end says so — read it first

A run before this one today ended non-green. The section headed "A PREVIOUS ATTEMPT TODAY
DID NOT REACH GREEN" tells you its verdict, what it tried, and two lists that bind you:

- **REJECTED** — a PR the audit found weakening a test or a check. **Do not merge it.**
  Do not re-land the same change under a new number. Either fix that PR so the weakening
  is gone, or close it and fix the ROOT CAUSE in a new one. The previous attempt was ended
  for reaching green cheaply; this attempt exists to do it properly.
- **PARKED** — a PR opened by a round that was cut off (the Mac slept, or the run hung).
  Nothing in it is verified. Read it before touching that repo; reuse what is sound,
  close what is not, and never assume it landed.

**A named stop beats a false green.** If a lane genuinely needs her — a credential, an
account, a real decision — say which lane and what decision, emit `blocked`, and stop.
That is a correct outcome. The wrapper will report main as red and say why, which is the
honest thing for it to say.

## Required final line

Your LAST line must be exactly one of these, with nothing after it:

    CI-SWEEP-COMPLETE: green        (nothing was red)
    CI-SWEEP-COMPLETE: fixed        (failures found; agents dispatched or fixes landed)
    CI-SWEEP-COMPLETE: blocked      (failures found that need her — say which, above)

The wrapper checks THIS ROUND'S OWN log for this sentinel. Without it the round is
recorded as SWEEP_ROUND_DID_NOT_COMPLETE, because a round that died halfway and a round
that finished with nothing to say produce the same silence otherwise. Emit it even when
the answer is "everything is green".

**This sentinel now means only "I reached my end."** It no longer decides how the sweep is
reported. After you emit it the wrapper probes main itself and writes the last line of the
log — `CI-SWEEP-COMPLETE: MAIN-GREEN`, `MAIN-RED-EXHAUSTED`, `MAIN-RED-STUCK`,
`MAIN-RED-TIMEOUT`, `MAIN-RED-TEMPFIX`, `MAIN-RED-BLOCKED`, `MAIN-RED-HUNG`,
`MAIN-RED-INTERRUPTED` or `MAIN-UNKNOWN` — from what GitHub says, not from what you say.
Every one of those except `MAIN-GREEN` schedules another attempt. **Writing `fixed` over a lane that is still red does not make the sweep
green; it just makes your round look worse than the truth.** Report accurately.
