#!/bin/bash
# Camille's Boss OS duty: own the Porch & Party Marketplace listings (job description: ~/bin/pnp-listings-job.md).
# launchd com.seq.boss-fb-renew runs this daily at 14:40 local (spread away from the morning jobs).
# The model runs ONLY when there is work: a renewal day (every 7 days from 23 Oct 2026), the site's
# rentals or services page changed since the last run, or FORCE=1. Other days cost nothing.
# Success on a renewal day marks p-n-p marketplace_renew_sent=today so the 16:00 CT backup reminder is skipped.
set -u
STATE=~/.boss-os/pnp-listings; LOG=~/Library/Logs/fb-renew/$(date +%F).log
today=$(TZ=America/Chicago date +%F)
n=$(( ( $(date -j -f %F "$today" +%s) - $(date -j -f %F 2026-10-23 +%s) ) / 86400 ))
renew_day=0; { [ $n -gt 0 ] && [ $((n % 7)) -eq 0 ]; } && renew_day=1
sig=$(for u in rentals services; do curl -fsS "https://porchandparty901.com/$u/" | sed 's/<[^>]*>/ /g' | tr -s ' \n'; done | shasum | cut -c1-16)
changed=0; [ "$sig" != "$(cat $STATE/site.sig 2>/dev/null)" ] && changed=1
[ "${FORCE:-0}" = 1 ] || [ $renew_day = 1 ] || [ $changed = 1 ] || { echo "$today nothing due" >> "$LOG"; exit 0; }
open -ga "Google Chrome"; sleep 20   # her Chrome must be open for Claude in Chrome
PROMPT="Today is $today (renewal day: $renew_day; site pages changed since last run: $changed).
$(cat ~/bin/pnp-listings-job.md)"
cd ~ && printf "%s" "$PROMPT" | /opt/homebrew/bin/claude -p --chrome --model opus --allowedTools="mcp__claude-in-chrome__*" >> "$LOG" 2>&1
last=$(grep -E "^(RESULT|STOP):" "$LOG" | tail -1)
echo "$(date) $last" >> "$LOG"
if [[ "$last" == RESULT:* ]]; then
  echo "$sig" > $STATE/site.sig; echo "$today $last" >> $STATE/results.log
  [ $renew_day = 1 ] && (cd ~/GitHub/p-n-p && npx wrangler d1 execute pnp-admin --remote --command "INSERT INTO settings (key, value) VALUES ('marketplace_renew_sent', '$today') ON CONFLICT(key) DO UPDATE SET value = excluded.value" >> "$LOG" 2>&1)
else
  [ "${FORCE:-0}" = 1 ] && exit 1
  cd ~/GitHub/boss-os && npm run -s notify -- --from Camille --subject "Marketplace listings: I couldn't finish today" \
    --body "What happened: ${last:-no result} (Chrome or Facebook could not be reached). What we did: nothing was changed; on a renewal day your 4pm reminder email has the steps. Status: I try again tomorrow." >> "$LOG" 2>&1
fi
