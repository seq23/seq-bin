#!/usr/bin/env bash
# A partner email on a card a developer has taken over never launches a tail (her rule, 15 Nov 2026:
# "always take it over"). Runs the watcher's own email query against a tiny SQLite copy of the tables.
set -u
here="$(dirname "$0")"; fail=0
db="$(mktemp)"; trap 'rm -f "$db"' EXIT
sql="$(grep -o 'SELECT message_id AS id[^|]*FROM inbound_message WHERE [^U]*' "$here/../scooter-watch.sh" | head -1 | sed -e "s/\\\\\"/\"/g" -e 's/\$PARTNER_A/partner-a/g; s/\$PARTNER_B/partner-b/g; s/\$STARTED_AT/2026-01-01/g; s/\$PARTNER_B_SINCE/2026-01-01/g')"
[ -n "$sql" ] || { echo "FAIL: email query not found in scooter-watch.sh"; exit 1; }
sqlite3 "$db" "CREATE TABLE work_card (id TEXT, held_reason TEXT);
CREATE TABLE inbound_message (message_id TEXT, received_at TEXT, from_address TEXT, to_address TEXT, subject TEXT, work_card_id TEXT);
INSERT INTO work_card VALUES ('wc_mine','A developer is doing this by hand (Sequoia): landing a fix'), ('wc_open', NULL);
INSERT INTO inbound_message VALUES ('m1','2026-11-15','partner-a@x','os@x','Re: preview','wc_mine'), ('m2','2026-11-15','partner-a@x','os@x','Re: other','wc_open'), ('m3','2026-11-15','partner-a@x','os@x','New ask',NULL);"
ids="$(sqlite3 "$db" "$sql" | cut -d'|' -f1 | sort | paste -sd, -)"
[ "$ids" = "m2,m3" ] || { echo "FAIL: expected m2,m3 tailed, got '$ids'"; fail=1; }
grep -q 'TAKEN OVER MEANS STOP' "$here/../scooter-watch.sh" || { echo "FAIL: the tail is not told to stop on a takeover"; fail=1; }
[ $fail = 0 ] && echo "test-scooter-watch-takeover: OK (taken-over card skipped, others tailed)"; exit $fail
