**Why:** on 22 Nov 2026 the GitHub API was rate-limited. Every read of westpeek-live deploy run 45044589982 failed, the wait hit its 14-minute ceiling, and the cancel failed too. land still reported NAMED STOP DEPLOY_RUN_PAST_CEILING ("ran past 14 min and was cancelled"). In fact the run had finished green, with smoke ok, in 3.5 minutes (16:34:31Z to 16:37:54Z).

**Fix:** `wait_run_bounded` now reads status and conclusion together. A failed read is treated as unknown:
- It cancels only a run it actually saw still going, and says `cancelled-at-ceiling` only when that cancel went through.
- Otherwise it returns `unread`. The deploy and promote waits stop on the new NAMED STOP `RUN_UNREAD`, which says the result is unknown and nothing was cancelled.

**Proof:** `tests/test-land-wait-run.sh` evals the new `wait_run` block verbatim with a stub `gh`. It is wired into validate.yml.
- **Mutation:** I put back the old ceiling branch (`gh run cancel ... || true; echo cancelled-at-ceiling`). Four cases went red: "rate-limited reads -> unread", "unread run is never cancelled", "no cancel sent" and "cancel refused -> unread, not cancelled".
- With the fix, all 6 cases pass. lint-shell is clean.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01CJ98gQuotzmQekevoSTPiy
