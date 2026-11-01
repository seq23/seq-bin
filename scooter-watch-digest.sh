#!/bin/bash
# Partner-tail weekly digest — Monday 08:00 CT (launchd com.seq.scooter-watch-digest), 6 Oct 2026.
#
# Compiles the last 7 days of state/mail-log.tsv (partner mail into the OS; mail from Scooter that
# went around Porter) and state/fix-log.md (what the tail agents found and fixed) into one
# plain-text email, sent through scooter-watch-report.mjs under the west-peek-os vault runner
# (Resend, os@westpeek.ventures -> her westpeek.ventures mailbox (OWNER_ADDR)).
#
# RETRY: the plist also fires at 09:00 Monday (like the CI sweep's retry). launchd runs a missed
# StartCalendarInterval at the next wake if the Mac was asleep at 08:00, so the 09:00 slot is the
# belt to that brace; this script sends at most once per ISO week (state/digest-last-sent), so a
# second firing after a successful send is a logged no-op.
set -uo pipefail
HOME_DIR="$HOME"
LOG_DIR="$HOME_DIR/Library/Logs/scooter-watch"
STATE_DIR="$LOG_DIR/state"
REPO="$HOME_DIR/GitHub/west-peek-os"
MAILLOG="$STATE_DIR/mail-log.tsv"
FIXLOG="$STATE_DIR/fix-log.md"
SENT_FILE="$STATE_DIR/digest-last-sent"
mkdir -p "$STATE_DIR"
exec >> "$LOG_DIR/digest.log" 2>&1

WEEK="$(date -u +%G-W%V)"
if [ "${1:-}" != "--force" ] && [ "$(cat "$SENT_FILE" 2>/dev/null)" = "$WEEK" ]; then
  echo "[digest] $(date -u +%Y-%m-%dT%H:%M:%SZ) already sent for $WEEK — no-op (retry slot)"
  exit 0
fi

EXPIRES_EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2027-01-05T05:59:59Z" +%s 2>/dev/null || date -u -d "2027-01-05T05:59:59Z" +%s)"
if [ "$(date -u +%s)" -ge "$EXPIRES_EPOCH" ]; then
  echo "[digest] window ended 4 Jan 2027 — the watch's finalize sends the final report; nothing to do"
  exit 0
fi

OUT="$STATE_DIR/digest-$(date -u +%Y%m%dT%H%M%SZ).txt"
python3 - "$MAILLOG" "$FIXLOG" "$OUT" <<'PY'
import sys, re, datetime as dt
from email.utils import parsedate_to_datetime
maillog, fixlog, out = sys.argv[1:4]
now = dt.datetime.now(dt.timezone.utc)
since = now - dt.timedelta(days=7)
def parse(s):
    s = s.strip()
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        try: return parsedate_to_datetime(s)
        except Exception: return None
into, around = [], []
for line in open(maillog, encoding="utf8"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 3: continue
    d = parse(f[0])
    if not d or d < since: continue
    src = f[3] if len(f) > 3 and f[3] else "os@"
    card = f[5] if len(f) > 5 else ""
    row = f"  - {d.strftime('%a %d %b %H:%M')}Z — {f[1]} — {f[2]}" + (f" (card {card})" if card else "")
    (around if src == "direct-to-sequoia" else into).append(row)
entries, cur, keep = [], [], False
for line in open(fixlog, encoding="utf8"):
    m = re.match(r"^## (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)", line)
    if m:
        if cur and keep: entries.append("".join(cur))
        d = parse(m.group(1)); keep = bool(d and d >= since); cur = [line]
    elif cur:
        cur.append(line)
if cur and keep: entries.append("".join(cur))
fixed = sum(1 for e in entries if re.search(r"\*\*Fix(ed)?:\*\*\s*(?!none)", e, re.I) and "github.com" in e)
with open(out, "w", encoding="utf8") as w:
    w.write(f"Partner tail — weekly digest, {since.strftime('%d %b')} to {now.strftime('%d %b %Y')}\n\n")
    w.write(f"Partner emails into the OS (tailed): {len(into)}\n" + ("\n".join(into) or "  - none") + "\n\n")
    w.write(f"Went around Porter (Scooter to Sequoia only, no os@, no work opened): {len(around)}\n" + ("\n".join(around) or "  - none") + "\n\n")
    w.write(f"Tail findings and fixes this week ({len(entries)} event(s), {fixed} fix(es) landed):\n" + ("\n".join(entries).strip() or "  - none") + "\n\n")
    w.write("Window runs through 4 Jan 2027. Fix log: ~/Library/Logs/scooter-watch/state/fix-log.md\n")
print(f"{len(into)} {len(around)} {fixed}")
PY
read -r N_INTO N_AROUND N_FIXED < <(python3 - "$OUT" <<'PY'
import sys,re
t=open(sys.argv[1],encoding="utf8").read()
g=lambda p: re.search(p,t).group(1)
print(g(r"into the OS \(tailed\): (\d+)"), g(r"no work opened\): (\d+)"), g(r"(\d+) fix\(es\) landed"))
PY
)
SUBJ="Partner tail digest: $N_INTO into the OS, $N_AROUND went around Porter, $N_FIXED fixed"
if RES="$(cd "$REPO" && node scripts/vault/vault.mjs run -- node "$HOME_DIR/bin/scooter-watch-report.mjs" "$OUT" "$SUBJ" 2>&1)"; then
  echo "$WEEK" > "$SENT_FILE"
  echo "[digest] $(date -u +%Y-%m-%dT%H:%M:%SZ) $RES"
else
  echo "[digest] $(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED: $RES"
  /usr/bin/osascript -e "display notification \"Weekly digest email failed — see $LOG_DIR/digest.log\" with title \"Partner tail\" subtitle \"needs a look\" sound name \"Basso\"" >/dev/null 2>&1
  exit 1
fi
