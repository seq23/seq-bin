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

## The comments are the point

These files carry more comment than code, and it is deliberate: each guard
records the incident that produced it. Do not delete one without understanding
what it caught.
