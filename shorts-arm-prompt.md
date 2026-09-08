Arm the How We Know Shorts lane. Work in ~/GitHub/how-we-know.

## Why this exists

`.github/workflows/loop-shorts-cloud.yml` is deliberately DISARMED — its `schedule:` block is
commented out and it is `workflow_dispatch` only. The file explains why: everything up to the
upload is proven (the R2 shelf resolves, evening slots compute, quota reserves, the whole lane
runs end to end against a stub), but `resumable_upload` through the repo-secret credential path
has never run. Arming a lane whose first real attempt happens unattended at 23:00 UTC against a
live channel is the thing that comment refuses to do.

51 Shorts are cut and waiting. On 2026-09-02 a `dry_run=true` dispatch succeeded and planned two
Shorts correctly. The real upload could not be tested that day because quota was 9,600/10,000
spent and a Short costs 1,600.

## Preconditions — check these first, and STOP if any fails

1. **Quota.** Read `loop/state/quota.json`. If its `day` is today (Pacific) and `spent` is above
   7,500, there is not enough headroom for a 1,600-unit Short plus the day's video upload. Stop
   with a named stop saying so — do NOT starve the publish lane.
2. **The lane is still disarmed.** Confirm the `schedule:` block in
   `.github/workflows/loop-shorts-cloud.yml` is still commented out. If it is already armed,
   there is nothing to do — say so and stop.
3. **main is green.** `gh run list --repo seq23/how-we-know --branch main --limit 3`. If main is
   red, stop — do not arm a lane on a broken main.

## Then, in order

1. **Dispatch one real upload:** `gh workflow run loop-shorts-cloud.yml -f limit=1`
2. **Wait for it to finish** and read the log with `gh run view <id> --log`. Do not proceed on a
   green check alone — read what the lane actually printed.
3. **Verify the Short is real and correct.** It must be PRIVATE with a `publishAt` in the future.
   Check via the YouTube API using the repo's own credentials — a short python script using
   `auth/tokens.py` and `videos.list?part=status,snippet` is the way. Confirm:
   - `privacyStatus` is `private`
   - `publishAt` is set and in the future
   - it is the Short the lane said it uploaded
4. **Only if all of that holds**, arm the cron: uncomment the two `schedule:` lines in
   `.github/workflows/loop-shorts-cloud.yml` (`- cron: '0 23 * * *'`), leave the surrounding
   comment block intact but update it to record that the lane has now completed a real upload
   end to end, on today's date, with the video id.
5. **Land it properly:** branch, commit with an explicit pathspec (never `git add -A`), push, open
   a PR, and merge ONLY when every required check is green — never with `--admin`, never
   force-pushed.

## Hard rules

- **Never set a video public.** The lane uploads private with a scheduled `publishAt`; that is the
  design.
- **Never delete a video.** If the test upload is wrong, retire it with `loop/retire.py`, which
  flips it to private and marks the ledger. There is deliberately no delete path in this repo and
  it must not gain one.
- **If the upload fails, do NOT arm the cron.** Report what failed. A lane that cannot upload once
  by hand must not be scheduled to try unattended every night.
- **Do not weaken any assertion** to get to green.

## Notify

Email `seq.taylor@gmail.com`, subject `Shorts lane`, under 150 words: whether it is armed, the
video id and its scheduled time if one was uploaded, and anything that needs her. If you stopped
on a precondition, say which one and when it will next be worth retrying.

## Required final line

    SHORTS-ARM-COMPLETE: armed
    SHORTS-ARM-COMPLETE: deferred
    SHORTS-ARM-COMPLETE: failed
    SHORTS-ARM-COMPLETE: already-armed

The wrapper checks for this sentinel; without it the run is recorded as incomplete.
