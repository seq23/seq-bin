## What

`gh`, put in `~/bin` (first on PATH), stands in front of Homebrew's gh. Every agent, `land`, `land-after`, `ci-sweep` and script now shares one GitHub allowance, and none of them changes a line.

On 22 Nov 2026 the account's 5,000 REST calls an hour were gone before 13:37Z, and gone again from 14:36Z. Demand measured from `gh api rate_limit` every minute, 14:01-14:21Z, was **3,094 calls in 19 min, about 9,700 an hour**, nearly double the allowance. For an hour at a time, `land` could not tell green from red.

- **One shared cache.** An identical read (`api` GET, `run`/`pr`/`issue`/`workflow`/`repo`/`release` view or list, `pr checks`) in the same repo within 20 s is answered from `~/.cache/gh-share`.
  - Only a real answer is kept: exit 0, or 8 for pending checks.
  - An expired answer is never served.
  - **Any write (merge, dispatch, comment) drops every kept answer, before it and again after it.** So land's "did it merge?" read always reaches GitHub. This was added in this round: without it, a `pr view` cached before a merge would have said OPEN for up to 20 s after it.
- **Watchers back off.** `run watch` and `pr checks --watch` poll no faster than every 30 s.
- **A low allowance waits; it does not fail.**
  - At or under 300 left, a read waits for the reset in one bounded sleep. The 300 are kept for writes, and writes are never held.
  - A reset further off than 3,700 s is `NAMED STOP [GH_ALLOWANCE_SPENT]`, exit 75.
- **A share per poller.** Each process group gets 500 GitHub reads an hour. Cache hits are free.
- **Fails toward working.**
  - A terminal on stdout (her own Terminal) goes straight to the real gh, as does a missing cache dir.
  - `GH_SHARE_OFF=1` turns it off.
- **Measured, not guessed.** Every call is one line in `~/.cache/gh-share/calls.log`.

This works with seq-bin #137 (land waits out a spent allowance). This PR keeps the allowance from being spent in the first place.

## Calls per hour, before and after

- **Before:** about 9,700 REST calls an hour of demand (above).
- **After:** this can only be measured once the change is in `~/bin`, which happens when it merges. I will read it from `calls.log` the first hour after landing with:
  `awk -v c="$(( $(date +%s) - 3600 ))" '$1 > c {n[$3]++} END {for (k in n) print k, n[k]}' ~/.cache/gh-share/calls.log`
  Calls that reach GitHub are miss + write + watch + graphql. The target is under 5,000 an hour with no `GH_ALLOWANCE_SPENT`. It is on the task sheet as the next step after land.

## Mutation proof (each part undone, `tests/test-gh-share.sh` goes red)

| Part undone | Red case |
|---|---|
| cache never read | 1: "10 identical reads made 10 GitHub calls, want 1" |
| floor never waits | 4: "the read at 0 allowance did not wait for the reset" |
| writes held like reads | 5: "a merge was held at a spent allowance" |
| watch interval not raised | 7: "gh run watch did not get --interval 30" |
| per-caller share never held | 8: "the third read of a 2-call share was not held" |
| no named stop past the wait | 6: "spent allowance: rc 124, want 75 + named stop" |
| a write does not drop the cache | 11: "a read after a merge was answered from before it" |

A mutant that kept an expired entry after a failed fetch stayed green. Expired entries are never served, so that `rm` did nothing. I deleted it and corrected the comment, and did not add a test that only checks wording. Cases 5 and 6 now run under `timeout 10`, so a mutant that sleeps fails in seconds instead of hanging CI.

## Tests run locally (changed files only)

- `tests/lint-shell.sh`: 81 scripts, clean.
- `tests/test-gh-share.sh`: 11 cases passed. It is added to `validate.yml`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01CJ98gQuotzmQekevoSTPiy

Owner override: "ship it, land #138 now" (22 Nov 2026 12:11 CT)

