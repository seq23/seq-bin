<!-- pr-body-template.md (seq-bin). Every line `land` can ask of a PR description, in the one form it accepts. Copy this into the PR body, fill each placeholder, and delete what a "delete if" note allows. A line still holding its placeholder counts as missing. `land --check PR` lists everything still missing in ONE run. -->

## What changed
<one or two plain sentences: what this does for the person who uses it>

<!-- land:REVIEW_CLASS_UNDECLARED — keep ONE of the two lines. Delete both only if the diff touches no payments, data, store or email path and the repo holds no data store: land then reads the paths itself. A class waits on a fresh reviewer's PASS; none lands on green CI. -->
Review class: none — <why this is in no review class, 3+ words>
Review class: <money | private-data | delete | store | launch | outreach> — <why>

<!-- land:FORMS_UNDECLARED — keep ONE of the two lines. Delete both if the diff touches no form page and no form server path. -->
Forms: none — <why no form page or server path is touched, 3+ words>
Forms: <which form(s)> — preview: <the marked TEST submission you made on the preview and what received it>

<!-- land:OUTCOME_UNDECLARED,OUTCOME_CHECK_NOT_READ_ONLY — keep ONE of the two lines; never delete both. A PR touching a schedule, plist, workflow cron, sender or agent script may not say none. The check may only read; by: may be left off (the next day). -->
Outcome: none — <why nothing scheduled or produced changes, 3+ words>
Outcome: <the real output that proves it works> — check: <a read-only shell command> — expect: >= <N> — by: <YYYY-MM-DD | next day | N days>

<!-- land:PATCH_OR_REBUILD_MISSING — delete if the PR changes no function a fix commit changed in the last 30 days (pr-patch-check says so when the PR opens). -->
Patch or rebuild: <why a patch and not a rebuild of that design, 5+ words> (<each fix ref land names, like #41>)

<!-- land:NOT_CLICKED_THROUGH — delete if the PR changes no screen people operate (src/client, .tsx, .jsx, .vue, .svelte). -->
Clicked through: <what you clicked, at 390 px, console clean>

<!-- builder:SELF_REVIEW — the builder's own proof, one line per check and per claim; the reviewer re-runs each command. land does not read it. -->
## Self-review
- <what is true>: `<the command you ran>` → <what it printed>
- <check>: n/a — <why, 4+ words>

<!-- land:MUTATION_PROOF_MISSING — keep the table (one row per fix), or only the one-line none. Delete both if the PR changes no code (docs, data or media only). -->
## Mutation proof
| Fix | Mutation made | Test that went red |
|---|---|---|
| <the fix> | <what you undid or broke> | <the test that went red> |
Mutation proof: none — <why there is no behaviour to break, 6+ words>

<!-- land:NOT_BUILT_UNDECLARED — never delete. Each item from the plan or brief this PR does not build, word for word; or the two words Nothing cut. -->
## Not built
<each item not built, word for word; or: Nothing cut.>

## Reviewer lines
<!-- The lines under this heading are never written by the builder: delete the heading and them from the body. A fresh reviewer posts them as a PR comment from the repo's owner account, naming the head it looked at. `Owner override:` is written only by `land --owner`, on her words. -->
<!-- land:REVIEW_PASS_MISSING,STALE_PASS — only for a PR in a review class (money, private-data, delete, store, launch, outreach, a review-required label, a change to live-repos.json). -->
Ship-ready: PASS — <fresh reviewer, its session or run id> looked at <the real output> at <head sha>; Engineering: PASS

<!-- land:LAUNCH_PASS_MISSING — only for something new going public (a first site, app, channel or listing). -->
Launch-ready: PASS — <fresh reviewer, its session or run id> looked at <logo, banner, bio, links, starter posts, 404, store assets> at <head sha>
