#!/bin/bash
#
# Partner tail (scooter-watch) — her 90-day tail on partner mail into the West Peek OS.
# Rewritten 6 Oct 2026 to her words that day: "when scooter cc me at sequoia@westpeek.ventures it
# should be watched all the time now until i decide to stop it (like 90 days) and it should launch
# a tail agent that tails the work and fixes any friction and records it and sends me a report".
#
# WINDOW: through 4 Jan 2027 23:59 CST (2027-01-05T05:59:59Z). At expiry: FINAL_REPORT.md,
# emailed, then both launchd jobs (this one and com.seq.scooter-watch-digest) boot themselves out.
# Runs every 15 minutes (launchd StartInterval 900; 27 Sep 2026, was 4-hourly).
#
# TRIGGER (the only one since 6 Oct 2026): a row in west-peek-os D1 `inbound_message` (os@joinwestpeek.com,
# Cloudflare email routing into the Worker) whose from_address is scooter@westpeek.ventures —
# cc'd to her or not. Her own os@ mail is not tailed, and her mailbox is not read (MAILBOX_SOURCE
# is off; 6 Oct 2026: "just make the tail for any email from scooter to the os@joinwestpeek"). Every such email dispatches ONE tail agent (queued if one is already in flight,
# picked up on the next free tick — the pre-6-Oct script marked queued mail seen and never
# returned to it).
#
# SOURCE 2 (read-only, no agent): her West Peek mailbox via the impersonation reader
# (scooter-watch-mail.mjs, metadata only, under the west-peek-os vault runner). A message from
# Scooter whose recipients do NOT include os@joinwestpeek.com is logged with source
# `direct-to-sequoia` and listed in the Monday digest as "went around Porter" — no work exists,
# nothing is tailed. This source's window starts at the first tick of this script (state/
# mailbox_since), not 24 Sep, so the first digest does not re-list three weeks of old threads.
#
# TAIL AGENT: one bounded, headless `claude -p --model opus` per event (scooter-watch-run-fix.sh,
# 2 h watchdog cap in scooter-watch-watchdog.sh). Scope = every work_card the email opened or
# steered, whichever employee owns it (Porter, Percy, Walker, ...). A genuine partner-decision
# wait is correct; friction (erroring, retrying without progress, re-asking for something already
# given, a "Blocked" email for an infrastructure wait, a repo the OS refused) is fixed at the root
# in west-peek-os, landed through ~/bin/land, logged in state/fix-log.md, and filed as ONE GitHub
# issue per friction fixed (label partner-tail). The agent ends by writing state/report-<stamp>.txt.
#
# REPORTS: one email per event when the agent finishes (or is killed), plus a Monday 08:00 CT
# digest (scooter-watch-digest.sh, its own launchd job) — both from os@westpeek.ventures to
# sequoia@westpeek.ventures through Resend via scooter-watch-report.mjs, which runs only under
# the vault runner (the key is injected by name, never on a command line, never logged).
#
# BANNERS: one on dispatch, one when mail queues, a heartbeat at most every 4 h otherwise.
set -uo pipefail

HOME_DIR="$HOME"
LOG_DIR="$HOME_DIR/Library/Logs/scooter-watch"
STATE_DIR="$LOG_DIR/state"
REPO="$HOME_DIR/GitHub/west-peek-os"
mkdir -p "$STATE_DIR"

RUN_LOG="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ).log"
ln -sf "$RUN_LOG" "$LOG_DIR/latest.log" 2>/dev/null || true
exec > >(tee -a "$RUN_LOG") 2>&1

LOCK="$LOG_DIR/.lock"
# A run killed mid-check (9 Oct 2026: a lock left 8 Oct 07:44 silenced every tick for 25 h) must
# never wedge the tail: the lock records its pid, and a lock whose pid is gone is broken and logged.
if ! mkdir "$LOCK" 2>/dev/null; then
  HOLDER="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
    echo "[lock] a check is already running (pid $HOLDER); exiting"
    exit 0
  fi
  echo "[lock] STALE lock (pid ${HOLDER:-none} not running) — breaking it and continuing"
  rm -rf "$LOCK"
  mkdir "$LOCK" || { echo "[lock] could not take the lock after breaking it"; exit 1; }
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

START_FILE="$STATE_DIR/started_at"
MAILBOX_SINCE_FILE="$STATE_DIR/mailbox_since"
SEEN_FILE="$STATE_DIR/seen-message-ids.txt"      # logged to mail-log (either source)
TAILED_FILE="$STATE_DIR/tailed-message-ids.txt"  # handed to a tail agent (os@ rows only)
MAILLOG="$STATE_DIR/mail-log.tsv"                # date \t from \t subject \t source \t message_id \t work_card_id
FIXLOG="$STATE_DIR/fix-log.md"
touch "$SEEN_FILE" "$MAILLOG" "$FIXLOG"

PARTNER_A="scooter@westpeek.ventures"
PARTNER_B="sequoia@westpeek.ventures"
# 22 Oct 2026, her word ("it should be tailed"): her own mail to os@ is tailed too, from this moment only
# (no backfill of earlier mail), so jobs she sends — e.g. The Learning Club — get the same tail as Scooter's.
PARTNER_B_SINCE="2026-10-22T16:16:59"
# 22 Oct 2026, her word ("why am i getting stuck emails… the tail should have fixed the friction"): every
# STUCK email the OS sends a partner is tailed too, so a card the sweep opened (not an os@ email) gets the
# same root-cause-and-fix. From this moment only; the two STUCK notices of 17:28/17:44Z have their own fix.
STUCK_SINCE="2026-10-22T19:55:00"
MAILBOX_SOURCE="off"   # 6 Oct 2026: Scooter → os@ is the only trigger; her own os@ mail and her mailbox are not tailed. Set "on" to restore the direct-to-sequoia log.
OS_MAILBOX="os@joinwestpeek.com"

if [ ! -s "$START_FILE" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$START_FILE"
  echo "[watch] first tick — window starts now"
fi
if [ ! -s "$MAILBOX_SINCE_FILE" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$MAILBOX_SINCE_FILE"
  echo "[watch] mailbox source (direct-to-sequoia) starts now"
fi
# Migration from the pre-6-Oct script: everything already seen had its tail; never re-dispatch it.
if [ ! -f "$TAILED_FILE" ]; then
  cp "$SEEN_FILE" "$TAILED_FILE"
  echo "[watch] tailed-ids file created from $(wc -l < "$SEEN_FILE" | tr -d ' ') already-seen id(s)"
fi
STARTED_AT="$(cat "$START_FILE")"
MAILBOX_SINCE="$(cat "$MAILBOX_SINCE_FILE")"
NOW_EPOCH="$(date -u +%s)"
# Window end: her approval 6 Oct 2026, "like 90 days" — 2027-01-04 23:59:59 CST = 2027-01-05T05:59:59Z.
EXPIRES_EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2027-01-05T05:59:59Z" +%s 2>/dev/null || date -u -d "2027-01-05T05:59:59Z" +%s)"

banner() {
  local title="$1" subtitle="$2" sound="${3:-}"
  local snd=""
  [ -n "$sound" ] && snd="sound name \"$sound\""
  /usr/bin/osascript -e "display notification \"$(printf '%s' "$subtitle" | sed 's/\"/\\\"/g')\" with title \"$(printf '%s' "$title" | sed 's/\"/\\\"/g')\" subtitle \"Partner tail\" $snd" \
    >/dev/null 2>&1 || echo "[notify] banner failed (no GUI session?)"
}

# send_report <file> <subject> — Resend from os@westpeek.ventures, key injected by the vault runner.
send_report() {
  local file="$1" subject="$2" out
  if out="$(cd "$REPO" && node scripts/vault/vault.mjs run -- node "$HOME_DIR/bin/scooter-watch-report.mjs" "$file" "$subject" 2>&1)"; then
    echo "[report] $out"
  else
    echo "[report] FAILED: $out"
    banner "Partner tail — report email failed" "See $RUN_LOG" "Basso"
    return 1
  fi
}

finalize() {
  echo "[finalize] window (through 4 Jan 2027) ended at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    echo "Partner tail — final report"
    echo
    echo "Window: $STARTED_AT -> $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Partner emails into the OS (tailed)"
    awk -F'\t' '($4=="" || $4=="os@") {print "- "$1" — "$2" — "$3}' "$MAILLOG"
    echo
    echo "## Went around Porter (sent to Sequoia only, no work opened)"
    awk -F'\t' '$4=="direct-to-sequoia" {print "- "$1" — "$3}' "$MAILLOG"
    echo
    echo "## Work tailed and fixes made"
    if [ -s "$FIXLOG" ]; then cat "$FIXLOG"; else echo "- no fixes were needed"; fi
  } > "$LOG_DIR/FINAL_REPORT.md"
  echo "[finalize] wrote $LOG_DIR/FINAL_REPORT.md"
  send_report "$LOG_DIR/FINAL_REPORT.md" "Partner tail: final report — window ended 4 Jan 2027"
  banner "Partner tail complete" "Window ended 4 Jan 2027 — report emailed; $LOG_DIR/FINAL_REPORT.md" "Glass"
  launchctl bootout "gui/$(id -u)" "$HOME_DIR/Library/LaunchAgents/com.seq.scooter-watch-digest.plist" 2>/dev/null
  launchctl bootout "gui/$(id -u)" "$HOME_DIR/Library/LaunchAgents/com.seq.scooter-watch.plist" 2>/dev/null
  exit 0
}

if [ "$NOW_EPOCH" -ge "$EXPIRES_EPOCH" ]; then
  finalize
fi

# ---------------------------------------------------------------------------------------------
# SOURCE 1 — OS inbound table (os@joinwestpeek.com), from Scooter. The primary trigger.
# ---------------------------------------------------------------------------------------------
# One retry (9 Oct 2026: 2 of 66 ticks failed on a transient D1 "success: false"; a failed tick only
# delays mail by 15 min, but a retry 20 s later costs nothing and keeps the log honest).
os_query() {
  (cd "$REPO" && npx wrangler d1 execute west-peek-os-db --remote --env production --json \
    --command "SELECT message_id AS id, received_at AS date, from_address AS \"from\", to_address AS \"to\", subject, work_card_id FROM inbound_message WHERE ((from_address LIKE '%$PARTNER_A%' AND received_at > '$STARTED_AT') OR (from_address LIKE '%$PARTNER_B%' AND received_at > '$PARTNER_B_SINCE')) UNION ALL SELECT 'stuck:' || n.id AS id, n.sent_at AS date, 'OS STUCK notice to ' || n.sent_to AS \"from\", n.sent_to AS \"to\", 'STUCK: ' || COALESCE(c.title, n.work_card_id) AS subject, n.work_card_id FROM work_card_notice n LEFT JOIN work_card c ON c.id = n.work_card_id WHERE n.kind = 'STUCK' AND n.sent_at > '$STUCK_SINCE' AND (n.sent_to LIKE '%$PARTNER_A%' OR n.sent_to LIKE '%$PARTNER_B%') ORDER BY date" 2>>"$RUN_LOG")
}
OS_JSON="$(os_query)"
if ! printf '%s' "$OS_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,list) and d and d[0].get("success",True) else 1)' 2>/dev/null; then
  echo "[watch] OS inbound query failed once (transient D1); retrying in 20 s"
  sleep 20
  OS_JSON="$(os_query)"
fi
if [ -z "$OS_JSON" ]; then
  echo "[watch] OS inbound check (west-peek-os D1) produced no output — treating as a failed check, not zero mail"
  banner "Partner tail — check failed" "OS inbound query returned nothing; see $RUN_LOG" "Basso"
  exit 1
fi
echo "$OS_JSON" > "$STATE_DIR/last-os-raw.json"
OS_ROWS="$(python3 - "$OS_JSON" <<'PY'
import sys, json
d1 = json.loads(sys.argv[1])
if not (isinstance(d1, list) and d1 and d1[0].get("success", True)):
    sys.exit("OS inbound query did not report success")
for r in d1[0].get("results", []):
    print("\t".join(str(r.get(k) or "").replace("\t", " ").replace("\n", " ") for k in ("id", "date", "from", "subject", "work_card_id")))
PY
)" || { echo "[watch] OS inbound query did not report success"; exit 1; }
OS_TOTAL="$(printf '%s' "$OS_ROWS" | grep -c . || true)"
echo "[watch] source 1: OS inbound table ($OS_MAILBOX), from Scooter — $OS_TOTAL row(s) since the window started"

NEW_OS=0
while IFS=$'\t' read -r id date from subject card; do
  [ -z "$id" ] && continue
  if ! grep -qxF "$id" "$SEEN_FILE"; then
    echo "$id" >> "$SEEN_FILE"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$date" "$from" "$subject" "os@" "$id" "$card" >> "$MAILLOG"
    NEW_OS=$((NEW_OS+1))
    echo "[watch] new OS mail from $from: $subject (card: ${card:-none yet})"
  fi
done <<< "$OS_ROWS"

# ---------------------------------------------------------------------------------------------
# SOURCE 2 — her West Peek mailbox, mail from Scooter (read-only, metadata). Anything without
# os@ among its recipients "went around Porter": logged for the digest, never tailed. A failure
# here is logged and counted, never fatal — source 1 is the trigger and still ran.
# ---------------------------------------------------------------------------------------------
NEW_DIRECT=0
MB_FAIL="$STATE_DIR/mailbox-failures"
WEEK_AGO="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
MB_SINCE="$MAILBOX_SINCE"; [ "$WEEK_AGO" \> "$MB_SINCE" ] && MB_SINCE="$WEEK_AGO"
if [ "$MAILBOX_SOURCE" != "on" ]; then
  : # 6 Oct 2026, her words: "just make the tail for any email from scooter to the os@joinwestpeek" — the mailbox source is off; only Scooter → os@ trips a tail.
elif MB_JSON="$(cd "$REPO" && node scripts/vault/vault.mjs run -- node "$HOME_DIR/bin/scooter-watch-mail.mjs" "$MB_SINCE" "$SEEN_FILE" 2>>"$RUN_LOG")" && [ -n "$MB_JSON" ]; then
  echo "$MB_JSON" > "$STATE_DIR/last-mail-raw.json"
  rm -f "$MB_FAIL"
  MB_ROWS="$(printf '%s' "$MB_JSON" | python3 -c '
import sys, json
for m in json.load(sys.stdin):
    rec = (m["to"] + " " + m["cc"]).lower()
    print("\t".join(x.replace("\t", " ").replace("\n", " ") for x in (m["id"], m["gmail_id"], m["date"], m["from"], m["subject"], "cc-os" if "os@joinwestpeek.com" in rec else "direct")))
')"
  MB_TOTAL="$(printf '%s' "$MB_ROWS" | grep -c . || true)"
  echo "[watch] source 2: her mailbox ($PARTNER_B), mail from Scooter since $MB_SINCE — $MB_TOTAL unseen row(s)"
  while IFS=$'\t' read -r id gmid date from subject kind; do
    [ -z "$id" ] && continue
    echo "gm:$gmid" >> "$SEEN_FILE"
    if [ "$kind" = "cc-os" ]; then
      echo "[watch] mailbox: os@ is on \"$subject\" — source 1 owns it"
      continue
    fi
    if ! grep -qxF "$id" "$SEEN_FILE"; then
      echo "$id" >> "$SEEN_FILE"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$date" "$from" "$subject" "direct-to-sequoia" "$id" "" >> "$MAILLOG"
      NEW_DIRECT=$((NEW_DIRECT+1))
      echo "[watch] went around Porter (no os@): $subject"
    fi
  done <<< "$MB_ROWS"
else
  N=$(( $(cat "$MB_FAIL" 2>/dev/null || echo 0) + 1 )); echo "$N" > "$MB_FAIL"
  echo "[watch] source 2: her mailbox read FAILED ($N consecutive) — see $RUN_LOG; source 1 still ran"
  [ $((N % 16)) -eq 1 ] && banner "Partner tail — mailbox read failing" "$N consecutive failures; see $RUN_LOG" "Basso"
fi

# ---------------------------------------------------------------------------------------------
# DISPATCH — every os@ row not yet handed to a tail agent. One agent at a time; the rest wait.
# ---------------------------------------------------------------------------------------------
PENDING="$(printf '%s\n' "$OS_ROWS" | awk -F'\t' -v tailed="$TAILED_FILE" 'BEGIN{while((getline l < tailed)>0) t[l]=1} $1!="" && !($1 in t)')"
PENDING_COUNT="$(printf '%s' "$PENDING" | grep -c . || true)"

FIXLOCK="$STATE_DIR/.fix-lock"
FIX_CAP_SECONDS=7200   # 2h hard kill (watchdog) — a single event's diagnosis+fix; detached from this tick.

if [ "$PENDING_COUNT" -gt 0 ] && [ -d "$FIXLOCK" ] && kill -0 "$(cat "$FIXLOCK/pid" 2>/dev/null)" 2>/dev/null; then
  RUNNING_SINCE="$(cat "$FIXLOCK/started_at" 2>/dev/null)"
  echo "[watch] $PENDING_COUNT email(s) waiting for a tail, but an agent is in flight (since $RUNNING_SINCE) — they stay queued for the next free tick"
  [ "$NEW_OS" -gt 0 ] && banner "Partner emailed the OS ($NEW_OS new)" "A tail agent is already working a prior email — this one queues" "Ping"
elif [ "$PENDING_COUNT" -gt 0 ]; then
  rm -rf "$FIXLOCK"
  CLAUDE="${SCOOTER_WATCH_CLAUDE_BIN:-$(command -v claude || echo /opt/homebrew/bin/claude)}"
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  TAIL_LOG="$STATE_DIR/tail-$STAMP.jsonl"
  PROMPT_FILE="$STATE_DIR/tail-$STAMP.prompt.txt"
  REPORT_FILE="$STATE_DIR/report-$STAMP.txt"
  EVENT_LINES="$(printf '%s\n' "$PENDING" | awk -F'\t' '{printf "  - %s | from %s | message_id %s | work_card_id %s | subject: %s\n", $2, $3, $1, ($5==""?"(none recorded)":$5), $4}')"
  SUBJECT_LINE="$(printf '%s\n' "$PENDING" | awk -F'\t' '{print $4}' | paste -sd ';' - | sed 's/;/; /g')"
  SENDER_LINE="$(printf '%s\n' "$PENDING" | awk -F'\t' '{print $3}' | sort -u | paste -sd ',' - | sed 's/,/, /g')"
  echo "[watch] dispatching a tail for $PENDING_COUNT email(s) from $SENDER_LINE: $SUBJECT_LINE"

  cat > "$PROMPT_FILE" <<PROMPT
You are the partner tail for the West Peek OS. A partner ($SENDER_LINE) just emailed the OS
mailbox ($OS_MAILBOX). $PENDING_COUNT email(s):
$EVENT_LINES

Repo: $REPO (production D1: west-peek-os-db, env production). Query it read-only with
  cd $REPO && npm run vault:run -- npx wrangler d1 execute west-peek-os-db --remote --env production --json --command "..."
Worker logs if useful: a bounded 'npx wrangler tail --env production' from the same directory.

SCOPE — every work_card this mail opened or steered, whichever employee owns it (Porter, Percy,
Walker, Wren, ...):
  1. inbound_message.work_card_id for each message_id above (the door's own link);
  2. email_thread rows whose subject/token matches a reply, and the object_id card they point at;
  3. work_card rows created or updated within 10 minutes of each received_at whose title, body,
     requested_by_email, secondary_partner_email or cc_emails mention the partner;
  4. any card those cards handed off to (assigned_from_card_id, work_card_hand_off).
Tail them: re-query state every couple of minutes; read work_card_note, work_card_instruction,
work_card_hand_off, work_card_notice and the outbound email_thread rows for each. You have up to
2 hours in total for diagnosis and fix; use it when a real fix needs it, never pad idle tailing.

CORRECT (leave alone): a card BLOCKED on block_who = a partner waiting for HIS/HER decision,
answer or approval; preview-before-landing (preview_first, approval gates); a plan waiting on
the partner's word to land. That is the OS working as designed.

FRICTION (fix at the root):
  - an agent erroring, or retrying without progress (work_attempts climbing, state unchanged,
    work_last_failure set);
  - the OS asking the partner for something the email already gave (a file, an answer, a link);
  - a "Blocked" email sent for an infrastructure wait (a sleeping Mac, a queue, a rate limit, a
    deploy) rather than a partner decision;
  - a repo or site the OS refused or could not map, when the partner named it plainly;
  - a reply that opened a stray new card instead of steering the open one;
  - anything AGENTS.md Rule 0 calls "runs but inert" on the path this work took.
KNOWN-BAD INPUT: STOP THE BUILD FIRST, PREVIEW SECOND (her rule, 9 Oct 2026). If you find that a
run in flight is working from input you KNOW is wrong or incomplete (a partner's answer cut
short, a brief missing items he wrote, the wrong repo, a stale file), do not let it finish and
email a preview you will have to correct: the partner must never get a known-wrong preview
followed by a corrected one (9 Oct 2026: a change list cut at 1,000 chars produced a preview at
18:38 CT and a corrected one at 18:56 CT). Order of work: (1) STOP the live run — set the
CLAIMED subscription_seat_run to status 'ABANDONED' with a resolution that names the bad input
(the Mac's claimer stops the job at its next progress ping, logged as "no longer ours"); (2) fix
the input on the card (block_answer, rebuilt_for, the brief) from the stored inbound message;
(3) fix the cause in the repo as below; (4) queue ONE rebuild. Exactly one preview email reaches
the partner for that reply. Record the stopped run id in the fix-log entry.

Fix in $REPO per the decide-and-fix and strengthen-tests-never-weaken rules: root-cause, fix at
source, never weaken or skip a test or validator, guard it with a test, open a PR, then
'gh pr checks <pr>' yourself and land it with '$HOME_DIR/bin/land <pr>' (watch main to a
terminal state; never take any agent's word for green). Do not run the full e2e suites locally
unless your change touches what they cover. Another session may be working in this repo: check
'git status', 'git branch -a' and open PRs for a sibling fix before building one, and never
reset or discard anything you did not write.

RECORD, for every event (fixed or not):
  a. APPEND one dated entry to $FIXLOG (never overwrite earlier entries), under 150 words:
     ## $(date -u +%Y-%m-%dT%H:%M:%SZ) — <card id(s) or "no card found">
     - **Partner's email:** <sender> — <subject>
     - **What the OS did:** <which employee took it, what state it reached>
     - **Friction:** <what, or "none — correctly waiting on the partner" / "none — done">
     - **Fix:** <PR link and what changed, or "none needed"> — CONFIRMED or SUSPECTED
     - **Issue:** <west-peek-os issue URL per friction fixed, or "none">
  b. For EACH friction you fixed, open ONE GitHub issue:
     gh issue create --repo seq23/west-peek-os --label partner-tail --title "[partner-tail] <friction in one line>" --body "<what the partner asked, what the OS did, root cause, fix PR, CONFIRMED/SUSPECTED>"
     (create the label first if missing: gh label create partner-tail --repo seq23/west-peek-os --color 7057ff --description "Friction found by the partner tail" --force)
     and reference the issue URL from the fix-log entry.
  c. FINISH by writing a plain-text report of at most 25 lines to $REPORT_FILE — it is emailed to
     Sequoia as-is. First line: the partner's subject(s). Then: what was asked, what the OS did
     (employee, card ids, final state), friction found, fixes landed (PR links), issues filed,
     and one line "FRICTION_FIXED: <n>" (0 if nothing was broken). No markdown tables.
PROMPT

  mkdir -p "$FIXLOCK"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$FIXLOCK/started_at"
  printf '%s\n' "$PENDING" | awk -F'\t' '{print $1}' >> "$TAILED_FILE"

  nohup "$HOME_DIR/bin/scooter-watch-run-fix.sh" "$PROMPT_FILE" "$TAIL_LOG" "$FIXLOCK" "$CLAUDE" "$REPORT_FILE" "$SUBJECT_LINE" \
    </dev/null >/dev/null 2>&1 &
  AGENT_PID=$!
  echo "$AGENT_PID" > "$FIXLOCK/pid"
  disown "$AGENT_PID" 2>/dev/null

  nohup "$HOME_DIR/bin/scooter-watch-watchdog.sh" "$AGENT_PID" "$FIX_CAP_SECONDS" "$FIXLOCK" "$FIXLOG" "$TAIL_LOG" "$REPORT_FILE" "$SUBJECT_LINE" \
    </dev/null >/dev/null 2>&1 &
  disown "$!" 2>/dev/null

  echo "[watch] tail agent dispatched detached (pid $AGENT_PID); log: $TAIL_LOG"
  banner "Partner emailed the OS ($PENDING_COUNT)" "Tail agent dispatched (up to 2h) — report by email when done" "Ping"
else
  echo "[watch] nothing new to tail this tick (Scooter → os@ only)"
  HB="$STATE_DIR/last-heartbeat"
  if [ ! -s "$HB" ] || [ $(( NOW_EPOCH - $(cat "$HB") )) -ge 14400 ]; then
    echo "$NOW_EPOCH" > "$HB"
    banner "Partner tail check" "No new partner email into the OS in the last 4 hours" ""
  fi
fi
exit 0
