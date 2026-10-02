# Build first, test in batches — rollout ledger (26 Sep 2026)

The shape (CLAUDE.md, "Build first, test in batches"): per merge only the fast check (typecheck,
unit, validators, build; ≤5 min), merge on green and deploy **staging** at once; the full
browser/e2e suite runs nightly on `main` (`schedule` + `workflow_dispatch`), never per merge, with a
job-level `timeout-minutes` at ~4× normal as a fault detector; **production** deploys only from a sha
the full suite passed. Reference implementation: seq23/sheila-creator-dashboard (#54, 08:00 UTC).

Discovery: every seq23 repo (37), every workflow's triggers and steps read via the GitHub API on
26 Sep 2026, plus each `package.json` for Playwright/Cypress/puppeteer deps and e2e scripts, plus
the scripts those workflows call where a browser could hide behind an npm alias.

## Classification

| Class | Meaning |
|---|---|
| **A — in scope** | a browser/e2e suite ran on `push` to main or `pull_request`; changed in this rollout |
| **B — already off the merge path** | the browser suite already runs only on schedule/dispatch |
| **C — no browser suite in CI** | no browser suite runs per merge (may exist locally / post-deploy only) |
| **D — no workflows** | the repo has no GitHub Actions at all |
| **skip** | excluded by the brief |

## Nightly hours (UTC), staggered

| Hour | Repo | Workflow |
|---|---|---|
| 07:00 | boss-os | `e2e.yml` (217 Playwright journeys, ceiling 60 min) |
| 07:20 | founder-dilution-dashboard | `e2e.yml` (Playwright journey, ceiling 10) |
| 07:40 | secondaries | `e2e.yml` (Playwright suite, ceiling 10) |
| 08:00 | sheila-creator-dashboard | `e2e.yml` (reference, landed earlier) |
| 08:20 | justbeingmercedes | `e2e.yml` (page in Chromium + screenshots, ceiling 10) |
| 10:30 (1st of month) | west-peek-os | `playwright.yml` (owner's choice, 23 Sep; unchanged) |

## Every repo

| Repo | Class | What changed | Production promote path |
|---|---|---|---|
| boss-os | **A** | #50: Playwright job out of `ci.yml` into `e2e.yml` (07:00 UTC + dispatch); `deploy.yml` fires on `e2e` success at the sha it passed and records a GitHub Deployment; guard `the-merge-gate-is-fast.mjs` reads both files (16 fixtures); `docs/DEPLOYING.md` "When production moves". Route: `E2E_WF="e2e"` (this PR) | nightly green → `deploy.yml`; by hand `land --promote boss-os [--run-e2e]`. `land <pr>` prints WAITING. No staging target. |
| founder-dilution-dashboard | **A** | #4: e2e step out of `validate.yml` into `e2e.yml` (07:20 UTC + dispatch); `promote.yml` fast-forwards the `production` branch on e2e success; Pages project `production_branch` switched `main` → `production` (API, 26 Sep); guard `scripts/validate-workflows.mjs` (9 fixtures); RUNBOOK | staging = `main` preview (main.founder-dilution-dashboard.pages.dev); production = `production` branch → dilution.joinwestpeek.com. By hand: `gh workflow run e2e.yml --ref main`, or `gh workflow run promote.yml -f sha=<green sha>` |
| secondaries | **A** | #11: same shape as above, `e2e.yml` 07:40 UTC, `promote.yml`, Pages `production_branch` → `production`, guard `scripts/validate_workflows.mjs`, RUNBOOK | staging = main.secondaries.pages.dev; production = `production` branch → venturedeals.joinwestpeek.com; same by-hand commands |
| justbeingmercedes | **A** | #4: `validate.yml` = `validate:static` (new browserless half of `scripts/validate.mjs`, 101 checks) + `npm test` (upload e2e) + guard; `e2e.yml` (`npm run screenshots`, 08:20 UTC + dispatch); `deploy.yml` publishes `staging` preview on push to main, justbeingmercedes.com only on e2e success (dispatch with a sha refused without a green run); guard `scripts/validate-workflows.mjs` (11 fixtures); RUNBOOK, CLAUDE.md | staging = staging.justbeingmercedes.pages.dev on every merge; production on nightly green via `deploy.yml`; by hand `gh workflow run e2e.yml --ref main` or `gh workflow run deploy.yml -f sha=<green sha>` |
| sheila-creator-dashboard | skip (done) | #54 earlier today | `land` stages, waits for `e2e`; `land --promote sheila-creator-dashboard [--run-e2e]` |
| how-we-know | skip (brief) | untouched — its loop lanes are the product | — |
| west-peek-os | **B** | none: `playwright.yml` is monthly + dispatch since 23 Sep (owner), `ci.yml` is the gate, `deploy.yml` fires on CI. Not moved to nightly: the owner set monthly; production is not gated on it and the route stays merge → production | `land <pr>` → production (unchanged) |
| westpeek-live | **C** | none: `validation.yml` runs validators + vitest only; Playwright is predeploy/postdeploy by hand (`deploy-cloudflare-worker.yml` is dispatch-only). Another agent active here; not touched | self-deploys (Workers Builds) |
| west-peek-network-os | **C** | none: `validate.yml` runs `validate:everything --tier=1`; the only tier-1 e2e row is the static `validate:e2e-coverage`; Playwright rows are tier 2+ (local/headed) | Pages on push |
| west-peek-pitch-lab | **C** | none: `validate:all` is static contracts (`validate-master-gauntlet.mjs` writes config, `route-smoke.mjs` is HTTP) | Pages on push |
| dream-wedding-builder | **C** | none: `ci.yml` runs `validate:all` = typecheck + vitest + structural; `test:e2e` (Playwright) is never invoked in CI | Workers Builds on push |
| local-guides-citation-velocity | **C** | none: `playwright` is a dependency named in the validation matrix only; `release:ci-validate` is a node router | Pages on push |
| sprylabs-hpc-site | **C** | none: `playwright.config.mjs` exists; no workflow or shard runs it | Pages on push |
| dailystory | **C** | none: `@playwright/test` dep, no script, no workflow uses it; workflows are Supabase deploy + monitors | Supabase functions on push |
| courtscope | **C** | none: `npm run verify` is "browserless" by name and by deps (astro check/build + node validators) | `deploy-cloudflare.yml` (validate only) |
| hicks-consulting-canonical | **C** | none: `postdeploy-smoke.yml` on push to main is `curl` against the live Pages URL (<1 min), no browser | Pages on push |
| approvalprep | **C** | none: `validate.yml` runs `validate:all` (node); `ux:browserless-report` only in scheduled lanes | Pages on push |
| WPP-llm | **C** | none: `ci.yml` is node validators + daily schedule; `artifact_consistency_e2e.py` is a python check | Pages on push |
| horse-legal-guide-velocity | **C** | none: node validators (`validate:assisted-operations-e2e` is a script test) | Pages on push |
| local-guides-generator | **C** | none: node validators; `smoke:buyouts` is HTTP | Pages on push (6 projects) |
| authority-backlink-network | **C** | none: scheduled lanes, no browser suite | Pages on push (3 projects) |
| p-n-p | **C** | none | Pages on push |
| creator-network | **C** | none | `land` → `npm run deploy:state` |
| join-west-peek-main | **C** | none: `entity-validation.yml` is node validators | Pages on push (3 projects) |
| cynthia-brown-dds-site | **C** | none | Pages on push |
| dianne-place-recovery-services | **C** | none | Pages on push |
| seq-bin | **C** | this PR: routes + tests + this ledger | the launchd working copy fast-forwards on `land` |
| sequoiataylor | **C** | none (1 workflow, no browser) | — |
| secondaries (see above) | | | |
| sheila-bruce | **D** | no workflows (Playwright dep exists, nothing runs it) | — |
| spry-vc, shannon-armstrong-bail-network, william-hurley, the-hairstylista, 901johnsons-site, charm-nest, hey-scooter-taylor, heygetonmylevel | **D** | no workflows | — |

## What `land` does now (this PR)

- `boss-os` route gains `E2E_WF="e2e"`: `land <pr>` merges on the fast CI run and prints WAITING;
  `land --promote boss-os [--run-e2e]` ships the newest e2e-green commit and records it. A route with
  `E2E_WF` no longer takes the "wait for the Deploy run on green main" branch (that deploy.yml fires
  on e2e now, and the newest Deploy run on main would have been an older commit's).
- The three Pages repos keep `SELF` routes (nothing for `land` to run); their sentences name staging
  and the e2e gate; `pages_watch` confirms the staging build on the merge commit as before.
- Tests: `tests/test-land-routes.sh` pins all of the above (negative proof: removing the E2E_WF guard
  fails it).

## Proven on 26 Sep 2026

- boss-os: `the-merge-gate-is-fast` fails with the journeys back in `ci.yml` and with `e2e.yml` on
  push (both tried, both red, both restored).
- founder-dilution-dashboard: `gh workflow run e2e.yml --ref main` → e2e run 36247662566 green →
  promote run 36247746594 moved `production` to d5709fd → Pages built `production` as production
  (14:13 UTC, dilution.joinwestpeek.com). Pages project `production_branch` = `production` since 14:08 UTC.
- secondaries: e2e run 36247740094 green → promote run 36247788501 moved `production` to 0799587 →
  Pages built it as production (14:13 UTC, venturedeals.joinwestpeek.com). `production_branch` switched 14:11 UTC.
- justbeingmercedes: merge 688b533 → Deploy (push) published https://staging.justbeingmercedes.pages.dev;
  production stayed on 254f6a1 until the dispatched e2e (run 36247845405) went green and Deploy (workflow_run 36247909014)
  published 688b533 to justbeingmercedes.com.
- boss-os: #50 landed with the OLD `land` (before this PR): main's fast CI went green in ~4 min, no
  Deploy run fired (deploy.yml now waits for e2e), production stayed on f92f9db — but `land` printed
  "the Deploy workflow shipped it" from the previous commit's Deploy run. That sentence is the bug the
  E2E_WF guard in this PR removes; boss-os's first production move is the 07:00 UTC nightly (or
  `land --promote boss-os --run-e2e`).

## 2 Oct 2026 — small changes ship on the fast check (supersedes "prints WAITING" above)

Owner, asked and answered: with the browser suites on demand only, a SMALL change ships to
production on the fast check alone; e2e gates production only after a LARGE change (`land`
measures it and runs the suite) or when asked (`--run-e2e`). Before this, `land <pr>` on a small
change printed WAITING for a green e2e nothing would ever run, and six repos sat on staging.

- **One definition of "large"**: the `large` block in `land`. The repos point at it; none restates
  the thresholds.
- **Every change production has not seen is judged**, not only the PR in hand (`range` block): a
  large commit whose suite never ran makes the next land run it.
- **Known red blocks**: the newest e2e run on main that reached a verdict (cancelled/skipped passed
  over) must be `success` or absent, else `NAMED STOP [E2E_KNOWN_RED]`. A red run on the exact sha
  blocks likewise. An unreadable history is exit 75.
- **Routes**: `secondaries`, `founder-dilution-dashboard` (`promote.yml`) and `justbeingmercedes`
  (`deploy.yml`) gain `E2E_WF="e2e"` and `PROMOTE_VIA` — land dispatches the repo's own workflow
  with `-f sha=` / `-f reason=` and reads the GitHub Deployment it records. `boss-os` gains
  `PROMOTE_WF="deploy.yml"`: after a green suite land waits for that run instead of deploying the
  same sha from the laptop (two `d1 migrations apply` at once).
- **In each repo**: the promote/deploy workflow's dispatch path accepts a sha with a green e2e, or
  — with a `reason` — a sha whose fast check is green while the suite is not known red; its
  validator pins both halves.
