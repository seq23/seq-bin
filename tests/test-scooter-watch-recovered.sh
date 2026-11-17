#!/usr/bin/env bash
# A card that failed an attempt, then recovered and now waits on the partner's own word (a preview, a
# question), raises no second friction event (17 Nov 2026: wc_76e6d7ff fired ":2:IN_PROGRESS", recovered,
# emailed its preview, then fired again as ":3:BLOCKED" and launched a tail for a card working as designed).
# Runs the watcher's own friction clause against a tiny SQLite copy of work_card.
set -u
here="$(dirname "$0")"; fail=0
db="$(mktemp)"; trap 'rm -f "$db"' EXIT
sql="$(grep -o "SELECT 'friction:' || id.* UNION ALL SELECT 'stall:" "$here/../scooter-watch.sh" | head -1 | sed -e "s/ UNION ALL SELECT 'stall:\$//" | sed -e "s/\\\\\"/\"/g" -e 's/\$STUCK_SINCE/2026-01-01/g')"
[ -n "$sql" ] || { echo "FAIL: friction query not found in scooter-watch.sh"; exit 1; }
sqlite3 "$db" "CREATE TABLE work_card (id TEXT, title TEXT, state TEXT, held_reason TEXT, work_attempts INT, work_last_failure_at TEXT, block_reason TEXT, blocked_at TEXT);
INSERT INTO work_card VALUES
 ('wc_recovered','t','BLOCKED',NULL,3,'2026-11-17','a_question_for_you','2026-11-17'),
 ('wc_retrying','t','IN_PROGRESS',NULL,2,'2026-11-17',NULL,NULL),
 ('wc_gave_up','t','BLOCKED',NULL,3,'2026-11-17','tried_and_could_not_finish','2026-11-17'),
 ('wc_clean','t','BLOCKED',NULL,1,NULL,'a_question_for_you','2026-11-17');"
ids="$(sqlite3 "$db" "$sql" | cut -d'|' -f1 | sed 's/^friction://; s/:.*//' | sort | paste -sd, -)"
[ "$ids" = "wc_gave_up,wc_retrying" ] || { echo "FAIL: expected wc_gave_up,wc_retrying, got '$ids'"; fail=1; }
[ $fail = 0 ] && echo "test-scooter-watch-recovered: OK (recovered card waiting on the partner raises no friction)"; exit $fail
