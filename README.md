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
| `ci-sweep.sh` | 10:07, 18:07 | Finds every red GitHub Actions lane, dispatches one fixing agent per repo, and iterates until main is green or it hits a bound. |
| `ci-sweep-probe.sh` | (called) | Asks GitHub directly what main's state is. This, not any agent's report, decides whether the sweep is finished. |
| `ci-sweep-audit.sh` | (called) | Reads the diff of everything that landed and fails the sweep on `continue-on-error`, `xfail`, `skip`, `--no-verify`, `\|\| true`, `set +e` in added lines. Reaching green by weakening a check is the defect this whole system exists to prevent. |
| `ci-sweep-notify.sh` | (called) | macOS banner plus a deduped GitHub issue when the sweep ends red. A green sweep notifies nobody. |
| `ci-sweep-prompt.md` | — | The brief the sweep runs headlessly. Carries the incident history that shaped it. |
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
  reaches its own check. See the supervisor and watchdog in `ci-sweep.sh`.

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
| `tests/test-rule-zero.sh` | The validators above hard-fail on zero items, with positive and negative controls. |

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
