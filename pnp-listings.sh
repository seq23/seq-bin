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
open -ga "Google Chrome"; sleep 20   # her Chrome must be open for Claude in Chrome
PROMPT="Today is $today (renewal day: $renew_day; site pages changed since last run: $changed).
$(cat ~/bin/pnp-listings-job.md)"
# ai-run --role brain (Claude), a NAMED EXCEPTION to the 3 Nov 2026 ruling (Codex does the hands-on
# work): this job drives her own Chrome through Claude in Chrome, which only Claude can reach. Same
# flags as before: Chrome tools only, no permission bypass.
last=""
for try in 1 2; do
  [ $try = 2 ] && { echo "$(date) no result on the first try (${last:-nothing said}); trying once more in 10 minutes" >> "$LOG"; sleep 600; open -ga "Google Chrome"; sleep 20; }
  mark=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  printf "%s" "$PROMPT" | AI_RUN_CLAUDE_ARGS='--chrome --allowedTools=mcp__claude-in-chrome__*' \
    ~/bin/ai-run --role brain --cwd ~ --out "$LOG" > /dev/null 2>&1
  last=$(tail -n +$((mark + 1)) "$LOG" | grep -E "^(RESULT|STOP):" | tail -1)
  echo "$(date) try $try: ${last:-no result}" >> "$LOG"
  [[ "$last" == RESULT:* ]] && break
  # Facebook wanting her own sign-in is not cured by trying again: stop and tell her.
  echo "$last" | grep -qiE "log ?in|sign ?in|password|checkpoint|captcha|verif|two-factor|2fa" && break
done
if [[ "$last" == RESULT:* ]]; then
  [ $read_ok = 1 ] && echo "$sig" > $STATE/site.sig
  rm -f $STATE/retry; echo "$today $last" >> $STATE/results.log
  [ $renew_day = 1 ] && (cd ~/GitHub/p-n-p && npx wrangler d1 execute pnp-admin --remote --command "INSERT INTO settings (key, value) VALUES ('marketplace_renew_sent', '$today') ON CONFLICT(key) DO UPDATE SET value = excluded.value" >> "$LOG" 2>&1)
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
