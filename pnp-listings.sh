#!/bin/bash
# Camille's Boss OS duty: own the Porch & Party Marketplace listings (job description: ~/bin/pnp-listings-job.md).
# launchd com.seq.boss-fb-renew runs this daily at 14:40 local (spread away from the morning jobs).
# The model runs ONLY when there is work: a renewal day (every 7 days from 23 Oct 2026), the site's
# rentals or services page changed since the last run, or FORCE=1. Other days cost nothing.
# Success on a renewal day marks p-n-p marketplace_renew_sent=today so the 16:00 CT backup reminder is skipped.
# 13 Nov 2026 (owner: a failed read retries itself; she is emailed only with a real to-do):
#  - the site read retries, and a read that still fails never counts as "the site changed";
#  - a run with no RESULT is tried once more after 10 minutes, then again on the next day's run
#    ($STATE/retry holds the count of failed days in a row) even when nothing else is due;
#  - she is emailed ONLY when Facebook wants her own sign-in (login, password, checkpoint, captcha),
#    once a day; any other failure is the team's: one fix job on the 3rd failed day in a row.
set -u
STATE=~/.boss-os/pnp-listings; LOG=~/Library/Logs/fb-renew/$(date +%F).log
today=$(TZ=America/Chicago date +%F)
n=$(( ( $(date -j -f %F "$today" +%s) - $(date -j -f %F 2026-10-23 +%s) ) / 86400 ))
renew_day=0; { [ $n -gt 0 ] && [ $((n % 7)) -eq 0 ]; } && renew_day=1
mkdir -p "$STATE" "$(dirname "$LOG")"
read_ok=1; pages=""
for u in rentals services; do
  page=$(curl -fsS --retry 3 --retry-delay 20 --retry-all-errors --max-time 60 "https://porchandparty901.com/$u/") || read_ok=0
  pages="$pages$page"
done
sig=$(printf "%s" "$pages" | sed 's/<[^>]*>/ /g' | tr -s ' \n' | shasum | cut -c1-16)
changed=0
if [ $read_ok = 1 ]; then [ "$sig" != "$(cat $STATE/site.sig 2>/dev/null)" ] && changed=1
else echo "$today NOTE [SITE_NOT_READ] the site pages could not be read after 3 tries; not counted as a change, read again on the next run" >> "$LOG"; fi
retry=0; [ -f $STATE/retry ] && retry=1
[ "${FORCE:-0}" = 1 ] || [ $renew_day = 1 ] || [ $changed = 1 ] || [ $retry = 1 ] || { echo "$today nothing due" >> "$LOG"; exit 0; }
# Real work first (owner, 1 Nov 2026: "the listings should show more of OUR REAL WORK"): bring the
# newest real job photos and clips onto this Mac before the model runs (~/bin/pnp-real-work.mjs,
# read-only, through the vault). A source that cannot be read is a NAMED STOP in the log and the
# listings work still runs, with the real-work files already here. The once-a-week "more photos,
# please" line in her morning email is Boss OS's own daily job (scripts/ops/pnp-photo-ask.mjs).
REAL=$STATE/real-work
real_out=$(cd ~/GitHub/boss-os && PNP_REAL_WORK_DIR="$REAL" node scripts/vault/vault.mjs run -- node ~/bin/pnp-real-work.mjs 2>&1); printf "%s\n" "$real_out" >> "$LOG"
printf "%s\n" "$real_out" | grep -q "^real work photos: OUTPUT " \
  || echo "$today NAMED STOP [REAL_PHOTOS_NOT_READ] the real-work photo step ended without its OUTPUT line; the listings run goes on with the photos already on this Mac" >> "$LOG"
open -ga "Google Chrome"; sleep 20   # her Chrome must be open for Claude in Chrome
PROMPT="Today is $today (renewal day: $renew_day; site pages changed since last run: $changed).
$(cat ~/bin/pnp-listings-job.md)

$(cat "$REAL/list.txt" 2>/dev/null || echo "REAL WORK ON THIS MAC: none could be listed today; use the site photos as before.")"
# ai-run --role brain (Claude), a NAMED EXCEPTION to the 3 Nov 2026 ruling (Codex does the hands-on
# work): this job drives her own Chrome through Claude in Chrome, which only Claude can reach. Same
# flags as before: Chrome tools only, no permission bypass.
# A Claude usage limit never ends the day's run (her word 13 Nov 2026: "not get stopped b/c of usage
# again"): a limit on the first model moves straight to the next model, and a limit on both waits an
# hour and starts over, until 9 pm. Only Claude can drive her Chrome, so the ladder is Claude's models.
LIMIT_RE='usage limit|limit reached|hit your [a-z ]*limit|out of (extra )?usage|rate.?limit|overloaded'
WAIT=${LISTINGS_LIMIT_WAIT:-3600}
last=""; model=opus; try=0; plain=0
while :; do
  try=$((try + 1))
  mark=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  printf "%s" "$PROMPT" | AI_RUN_CLAUDE_MODEL=$model AI_RUN_CLAUDE_ARGS='--chrome --allowedTools=mcp__claude-in-chrome__*' \
    ~/bin/ai-run --role brain --cwd ~ --out "$LOG" > /dev/null 2>&1
  new=$(tail -n +$((mark + 1)) "$LOG")
  last=$(printf "%s\n" "$new" | grep -E "^(RESULT|STOP):" | tail -1)
  echo "$(date) try $try ($model): ${last:-no result}" >> "$LOG"
  [[ "$last" == RESULT:* ]] && break
  # Facebook wanting her own sign-in is not cured by trying again: stop and tell her.
  echo "$last" | grep -qiE "log ?in|sign ?in|password|checkpoint|captcha|verif|two-factor|2fa" && break
  if [ -z "$last" ] && printf "%s\n" "$new" | tail -n 20 | grep -qiE "$LIMIT_RE"; then
    if [ $model = opus ]; then model=sonnet; echo "$(date) usage limit on the first model; trying the next model now" >> "$LOG"; continue; fi
    [ "$(date +%H)" -ge 21 ] && { last="STOP: Claude usage limit on every model, all day"; break; }
    echo "$(date) usage limit on every model; trying again in $((WAIT / 60)) minutes" >> "$LOG"
    sleep "$WAIT"; model=opus; open -ga "Google Chrome"; sleep 20; continue
  fi
  [ $plain = 1 ] && break; plain=1
  echo "$(date) no result on the first try (${last:-nothing said}); trying once more in 10 minutes" >> "$LOG"; sleep ${LISTINGS_RETRY_WAIT:-600}; open -ga "Google Chrome"; sleep 20
done
if [[ "$last" == RESULT:* ]]; then
  [ $read_ok = 1 ] && echo "$sig" > $STATE/site.sig
  rm -f $STATE/retry; echo "$today $last" >> $STATE/results.log
  # A real photo the Chrome tools would not attach is the team's to fix, never hers: say so in the log.
  echo "$last" | grep -qi "attach refused" && echo "$today NAMED STOP [REAL_PHOTOS_NOT_ATTACHED] the Chrome tools refused a real-work file; the listings kept their current photos ($last)" >> "$LOG"
  # Through the vault: wrangler's own sign-in on this Mac expires, and then this write failed in
  # silence, so Valerie kept being told to renew by hand (found 13 Nov 2026).
  [ $renew_day = 1 ] && { (cd ~/GitHub/boss-os && node scripts/vault/vault.mjs run -- bash -c "cd ~/GitHub/p-n-p && npx wrangler d1 execute pnp-admin --remote --command \"INSERT INTO settings (key, value) VALUES ('marketplace_renew_sent', '$today') ON CONFLICT(key) DO UPDATE SET value = excluded.value\"" >> "$LOG" 2>&1) \
    || echo "$today NAMED STOP [RENEW_MARK_NOT_SAVED] the site was not told the listings are done; the 4 pm reminder will still go" >> "$LOG"; }
else
  [ "${FORCE:-0}" = 1 ] && exit 1
  days=$(( $(cat $STATE/retry 2>/dev/null || echo 0) + 1 )); echo $days > $STATE/retry
  echo "$today NAMED STOP [LISTINGS_NOT_DONE] ${last:-no result} (failed day $days in a row; the next daily run tries again)" >> "$LOG"
  if echo "$last" | grep -qiE "log ?in|sign ?in|password|checkpoint|captcha|verif|two-factor|2fa"; then
    # The one real to-do: only she can sign in to her own Facebook. Once a day.
    if [ "$(cat $STATE/signin-told 2>/dev/null)" != "$today" ]; then
      cd ~/GitHub/boss-os && npm run -s notify -- --from Camille --subject "Marketplace listings: Facebook needs you to sign in" \
        --body "Please sign in to Facebook in Chrome on your Mac; that is the one thing to do. What happened: Facebook asked for your sign-in, so the listings were not renewed or updated today. What we did: nothing was changed. Status: I try again tomorrow by myself once you are signed in." >> "$LOG" 2>&1 \
        && echo "$today" > $STATE/signin-told
    fi
  elif [ $days = 3 ]; then
    # Not hers to fix: one repair for the team on the 3rd failed day in a row, never an email to her.
    cd ~/GitHub/boss-os && LISTINGS_LAST="${last:-no result line}" node scripts/vault/vault.mjs run -- node -e 'import("./scripts/ops/lib/duty-kit.mjs").then(async (k) => { const why = await k.fixJob(await k.bossApi(), { title: "Marketplace listings: the daily run has failed 3 days in a row", prompt: "the Porch & Party Marketplace listings job on her Mac (~/bin/pnp-listings.sh, launchd com.seq.boss-fb-renew, log ~/Library/Logs/fb-renew/) has ended without a RESULT line three days running. Its last line: " + process.env.LISTINGS_LAST + ". Find why (Chrome not open, the Claude in Chrome extension not connected, the model seat), fix it at source, and run it once with FORCE=1." }); if (why) { console.error("NOTE [FIX_JOB_NOT_OPENED] " + why); process.exit(1); } console.log("fix job opened for the team"); })' >> "$LOG" 2>&1
  fi
fi
