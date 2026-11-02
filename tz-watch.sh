#!/bin/bash
# Keep every launchd job on its CENTRAL time when the Mac changes zone (launchd com.seq.tz-watch).
#
# WHY (1 Nov 2026). Every job is written in Central and launchd fires on the Mac's own clock, so each
# installer moves the hours to the Mac's zone (boss-os scripts/ops/plist-central.mjs, the one mover).
# That move happened only at install time; she travels between Central and Eastern and the Mac
# switches zone by itself, so every job then ran an hour off until someone reinstalled.
#
# WHAT IT DOES. Fires when /etc/localtime changes, at login and hourly. Reads the Mac's zone and the
# Central-to-local offset (centralToLocalOffset: both zones' DST, read at noon so a clock-change night
# cannot fool it). For each installer whose recorded offset differs, it runs that installer again and
# records "<zone> <offset>" for it in ~/Library/Application Support/tz-watch/. Same offset = no-op
# (a new zone name with the same offset is only recorded). Each installer rebuilds its plists from the
# Central source, so a reinstall is always from Central, never a shift of an already-shifted file.
#
#   seq-bin      ~/bin/install-launchd.sh <every label but com.seq.tz-watch>
#   boss-os      ~/.boss-os/runtime/scripts/ops/install-agent-launchd.sh (runs simone-commands and
#                mail-tail too)
#   how-we-know  ~/GitHub/how-we-know/bin/loop-install-launchd.sh --install (when its jobs are installed)
#
# A scheduled job mid-run is not killed: the seq-bin and boss-os installers wait (TZ_WATCH_DEFERRED,
# retried hourly) for up to 6 hours, then go ahead. how-we-know defers a running night itself; its
# "DEFERRED" line leaves it unrecorded, so the next hour tries again.
# An installer that fails is NAMED STOP [TZ_WATCH_INSTALL_FAILED] here and an Open Loops row (token
# from the Boss OS vault at run time, only on a change of state); the next success closes it.
#
#   ~/bin/tz-watch.sh        # what launchd runs; log ~/Library/Logs/tz-watch.log (last 1000 lines)
# Test: tests/test-tz-watch.sh (TZ_WATCH_* overrides exist for it only).
set -uo pipefail
BIN="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE="${TZ_WATCH_STATE:-$HOME/Library/Application Support/tz-watch}"
LOG="${TZ_WATCH_LOG:-$HOME/Library/Logs/tz-watch.log}"
AGENTS="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LCTL="${LAUNCHCTL:-launchctl}"
DEFER_MAX_S=$(( ${TZ_WATCH_DEFER_MAX_H:-6} * 3600 ))
SELF="com.seq.tz-watch"
BOSS="${BOSS_OS_REPO:-$HOME/.boss-os/runtime}"
[ -f "$BOSS/scripts/ops/plist-central.mjs" ] || BOSS="$HOME/GitHub/boss-os"
CENTRAL="$BOSS/scripts/ops/plist-central.mjs"
mkdir -p "$STATE"
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
say(){ echo "$(date '+%Y-%m-%d %H:%M %Z') $*"; }
stop(){ say "NAMED STOP [$1] $2"; exit "${3:-1}"; }

zone="${TZ_WATCH_ZONE:-$(readlink /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')}"
[ -n "$zone" ] || stop TZ_WATCH_NO_ZONE "could not read the Mac's zone from /etc/localtime; nothing changed." 3
[ -f "$CENTRAL" ] || stop NO_PLIST_CENTRAL "$CENTRAL not found: the Central-time mover lives in boss-os; nothing changed." 2
offset=$(TZ="$zone" node --input-type=module -e "import { centralToLocalOffset } from '$CENTRAL'; console.log(centralToLocalOffset())") \
  || stop TZ_WATCH_NO_OFFSET "node could not compute the Central offset for $zone; nothing changed." 3
want="$zone $offset"

# name|command, one per line. The installers themselves rebuild from Central; this only decides when.
installers() {
  if [ -n "${TZ_WATCH_INSTALLERS:-}" ]; then printf '%s\n' "$TZ_WATCH_INSTALLERS"; return; fi
  local labels="" f l
  for f in "$BIN"/launchd/*.plist; do l="$(basename "$f" .plist)"; [ "$l" = "$SELF" ] || labels="$labels $l"; done
  echo "seq-bin|$BIN/install-launchd.sh$labels"
  echo "boss-os|BOSS_OS_RUNTIME='$BOSS' bash '$BOSS/scripts/ops/install-agent-launchd.sh'"
  if ls "$AGENTS"/com.howweknow.*.plist >/dev/null 2>&1; then
    echo "how-we-know|$HOME/GitHub/how-we-know/bin/loop-install-launchd.sh --install"
  fi
}

# Scheduled (StartCalendarInterval) jobs running right now, outside how-we-know (which guards itself).
running_jobs() {
  local f l pid out="" listing
  listing="$("$LCTL" list 2>/dev/null)"
  for f in "$AGENTS"/*.plist; do
    l="$(basename "$f" .plist)"
    case "$l" in "$SELF"|com.howweknow.*) continue ;; esac
    grep -q '<key>StartCalendarInterval</key>' "$f" 2>/dev/null || continue
    pid=$(printf '%s\n' "$listing" | awk -v l="$l" '$3 == l { print $1 }')
    case "$pid" in ''|-|0) ;; *) out="$out $l" ;; esac
  done
  echo "$out"
}

post_row() {  # $1 = JSON body; only on a change of state, so the vault is read rarely
  if [ "${TZ_WATCH_NO_VAULT:-}" = 1 ]; then node "$BIN/open-loops.mjs" "$1"; return; fi
  local vr="$BOSS"; [ -f "$vr/scripts/vault/vault.mjs" ] || vr="$HOME/GitHub/boss-os"
  (cd "$vr" && npm run -s vault:run -- node "$BIN/open-loops.mjs" "$1")
}

todo=0 done_n=0 failed="" deferred=""
while IFS='|' read -r name cmd; do
  [ -n "$name" ] || continue
  have="$(cat "$STATE/$name" 2>/dev/null || true)"
  if [ "${have##* }" = "$offset" ] && [ -n "$have" ]; then
    [ "$have" = "$want" ] || { echo "$want" > "$STATE/$name"; say "$name: zone now $zone, same offset ($offset h from Central); nothing to move."; }
    continue
  fi
  todo=$((todo + 1))
  if [ "$name" != how-we-know ]; then
    busy="$(running_jobs)"
    if [ -n "$busy" ]; then
      [ -s "$STATE/pending-since" ] || date +%s > "$STATE/pending-since"
      if [ $(( $(date +%s) - $(cat "$STATE/pending-since") )) -lt "$DEFER_MAX_S" ]; then
        say "NOTE [TZ_WATCH_DEFERRED] $name: jobs running now ($busy); not reinstalling under them. Retried hourly."
        deferred="$deferred $name"; continue
      fi
      say "$name: jobs still running after ${TZ_WATCH_DEFER_MAX_H:-6} h ($busy); reinstalling anyway."
    fi
  fi
  say "$name: installed for '${have:-nothing recorded}', Mac is '$want'; reinstalling."
  out="$(TZ="$zone" BOSS_OS_REPO="$BOSS" bash -c "$cmd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -n 20 | sed 's/^/    /'
  if [ $rc -ne 0 ]; then
    say "NAMED STOP [TZ_WATCH_INSTALL_FAILED] $name exited $rc; its jobs may still be on the old zone. Retried hourly."
    failed="$failed $name"
  elif printf '%s\n' "$out" | grep -q '^DEFERRED'; then
    say "NOTE [TZ_WATCH_DEFERRED] $name deferred a running job itself; not recorded, retried hourly."
    deferred="$deferred $name"
  else
    echo "$want" > "$STATE/$name"; done_n=$((done_n + 1))
    say "$name: installed for $want."
  fi
done < <(installers)

[ -n "$deferred" ] || rm -f "$STATE/pending-since"
if [ -n "$failed" ]; then
  if [ "$(cat "$STATE/open-row" 2>/dev/null)" != "$failed" ]; then
    body=$(printf '{"repo":"seq23/seq-bin","owner":"claude","business":"personal","stop":"TZ_WATCH_INSTALL_FAILED","title":"Jobs not moved to the Mac'"'"'s new time zone (%s)","finish_line":"every installer reinstalled for %s","next_step":"Read ~/Library/Logs/tz-watch.log, fix the failing installer(s):%s. tz-watch retries every hour."}' "$zone" "$zone" "$failed")
    if post_row "$body"; then echo "$failed" > "$STATE/open-row"; else say "NAMED STOP [OPEN_LOOPS_POST_FAILED] the Open Loops row could not be posted; the log line above stands."; fi
  fi
  exit 1
fi
if [ -s "$STATE/open-row" ] && [ -z "$deferred" ]; then
  post_row '{"repo":"seq23/seq-bin","owner":"claude","business":"personal","stop":"TZ_WATCH_INSTALL_FAILED","cleared":true,"finish_line":"every installer reinstalled for the Mac'"'"'s zone"}' && rm -f "$STATE/open-row"
fi
if [ "$todo" -eq 0 ]; then say "in step: every installer is on $want."; else say "done: $done_n of $todo reinstalled for $want${deferred:+; deferred:$deferred}."; fi
exit 0
