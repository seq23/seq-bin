#!/bin/bash
# mac-window (the Mac's day, her ruling 21 Nov 2026): each class at the boundary minutes, "wait instead
# of running" (woken outside -> one pending record -> catch-up starts it once when the window opens),
# the no-double-run case (the job's own slot is still to come in the open window), paused jobs never
# woken, the heavy-slot cap, and the 06:55 stop path (TERM, the job saves its place, exits clean).
# Everything runs against a temp state dir, fake LaunchAgents and a fake launchctl.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MW="$HERE/mac-window"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MAC_WINDOW_STATE="$T/state" MAC_WINDOW_AGENTS="$T/agents" LAUNCHCTL="$T/launchctl" PBS_FILL_FILE="$T/no-fill"
mkdir -p "$T/agents"
cat > "$T/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$T/lctl.log"
[ "\$1" = print-disabled ] && { echo 'disabled services = {'; cat "$T/disabled" 2>/dev/null; echo '}'; }
exit 0
EOF
chmod +x "$T/launchctl"
fail=0; pass=0
ok() { pass=$((pass+1)); }
no() { fail=$((fail+1)); echo "FAIL: $*"; }
plist() {  # label hour minute
  cat > "$T/agents/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$1</string><key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>$2</integer><key>Minute</key><integer>$3</integer></dict></dict></plist>
EOF
}

# 1. Boundaries: class time expected(0 inside / 1 outside)
while read -r cls at want; do
  MAC_WINDOW_NOW=$at "$MW" check "$cls" >/dev/null; got=$?
  [ "$got" = "$want" ] && ok || no "check $cls $at gave $got, want $want"
done <<'EOF'
HEAVY 06:30 0
HEAVY 06:31 1
HEAVY 06:59 1
HEAVY 07:00 1
HEAVY 09:59 1
HEAVY 10:00 1
HEAVY 21:59 1
HEAVY 22:00 0
MORNING 06:59 0
MORNING 07:00 1
MORNING 09:59 1
MORNING 10:00 0
MORNING 21:59 0
MORNING 22:00 0
LIGHT 06:59 1
LIGHT 07:00 1
LIGHT 09:59 1
LIGHT 10:00 0
LIGHT 21:59 0
LIGHT 22:00 1
ANY 06:59 0
ANY 07:00 1
ANY 09:59 1
ANY 10:00 0
ANY 21:59 0
ANY 22:00 0
EOF
"$MW" --self-test >/dev/null && ok || no "self-test"

# 2. Woken outside: never runs, one named line, one pending record (a second wake does not add one).
out=$(MAC_WINDOW_NOW=06:40 "$MW" run LIGHT com.seq.t-light -- touch "$T/ran-light")
[ ! -e "$T/ran-light" ] && ok || no "LIGHT ran at 06:40"
echo "$out" | grep -q "^.*OUTSIDE_WINDOW com.seq.t-light LIGHT " && grep -q '"class": "LIGHT"' "$T/state/pending/com.seq.t-light" && ok || no "named line and pending record: $out"
MAC_WINDOW_NOW=06:45 "$MW" run LIGHT com.seq.t-light -- touch "$T/ran-light" | grep -q "already pending" && ok || no "second wake"
[ "$(ls "$T/state/pending" | wc -l | tr -d ' ')" = 1 ] && ok || no "one pending record"
out=$(MAC_WINDOW_NOW=08:00 "$MW" run HEAVY com.seq.t-heavy -- touch "$T/ran-heavy")
[ ! -e "$T/ran-heavy" ] && ok || no "HEAVY ran at 08:00"
echo "$out" | grep -q "opens at 22:00" && ok || no "heavy waits for 22:00: $out"

# 3. Catch-up before the window opens: waits. At 10:00 (job's own slot was 07:15, past): started once.
plist com.seq.t-light 7 15
MAC_WINDOW_NOW=09:50 "$MW" catch-up | grep -q "PENDING_WAITS com.seq.t-light" && ok || no "catch-up waits before 10:00"
grep -q kickstart "$T/lctl.log" 2>/dev/null && no "kickstarted before the window" || ok
MAC_WINDOW_NOW=10:00 "$MW" catch-up | grep -q "CAUGHT_UP com.seq.t-light" && ok || no "catch-up at 10:00"
[ "$(grep -c "kickstart gui/$(id -u)/com.seq.t-light" "$T/lctl.log")" = 1 ] && ok || no "kickstarted once"
# the kickstarted run comes back through the guard, inside now: it runs and clears the record
MAC_WINDOW_NOW=10:01 "$MW" run LIGHT com.seq.t-light -- touch "$T/ran-light" | grep -q PENDING_CLEARED && ok || no "run clears pending"
[ -e "$T/ran-light" ] && ok || no "LIGHT ran at 10:01"
[ ! -e "$T/state/pending/com.seq.t-light" ] && ok || no "record gone"
MAC_WINDOW_NOW=10:30 "$MW" catch-up >/dev/null
[ "$(grep -c "kickstart gui/$(id -u)/com.seq.t-light" "$T/lctl.log")" = 1 ] && ok || no "ran once only (second catch-up started it again)"

# 4. NO DOUBLE RUN: the heavy job's own 23:00 slot comes inside the window open at 22:00 -> left to it.
plist com.seq.t-heavy 23 0
MAC_WINDOW_NOW=22:00 "$MW" catch-up | grep -q "PENDING_LEFT com.seq.t-heavy" && ok || no "own slot left to run it"
grep -q "kickstart gui/$(id -u)/com.seq.t-heavy" "$T/lctl.log" && no "heavy double-started" || ok
MAC_WINDOW_NOW=23:00 MAC_WINDOW_STOP_IN=30 "$MW" run HEAVY com.seq.t-heavy -- touch "$T/ran-heavy" >/dev/null
[ -e "$T/ran-heavy" ] && [ ! -e "$T/state/pending/com.seq.t-heavy" ] && ok || no "own slot ran it and cleared the record"
# ...and a job whose own slot already passed today is started by the catch-up instead
plist com.seq.t-light2 10 5
MAC_WINDOW_NOW=06:50 "$MW" run LIGHT com.seq.t-light2 -- true >/dev/null
MAC_WINDOW_NOW=10:00 "$MW" catch-up | grep -q "PENDING_LEFT com.seq.t-light2" && ok || no "10:05 slot owns the run"
MAC_WINDOW_NOW=10:30 "$MW" catch-up | grep -q "CAUGHT_UP com.seq.t-light2" && ok || no "missed 10:05 (Mac booted late) -> caught up"

# 5. Paused jobs are never woken: a disabled label, a YouTube job while the PBS fill holds the channels.
MAC_WINDOW_NOW=08:00 "$MW" run LIGHT com.seq.t-paused -- true >/dev/null
echo '		"com.seq.t-paused" => disabled' > "$T/disabled"
MAC_WINDOW_NOW=10:00 "$MW" catch-up | grep -q "PENDING_PAUSED com.seq.t-paused: disabled" && ok || no "disabled not woken"
if grep "kickstart" "$T/lctl.log" | grep -q "com.seq.t-paused"; then no "kickstarted a disabled job"; else ok; fi
touch "$T/fill"; MAC_WINDOW_NOW=08:00 "$MW" run LIGHT com.howweknow.backfill -- true >/dev/null
PBS_FILL_FILE="$T/fill" MAC_WINDOW_NOW=10:30 "$MW" catch-up | grep -q "PENDING_PAUSED com.howweknow.backfill: YouTube" && ok || no "YouTube held"
if grep "kickstart" "$T/lctl.log" | grep -qE "t-paused|howweknow"; then no "a paused job was kickstarted"; else ok; fi
# launchd unreadable: catch-up fails closed (starts nothing, named stop, exit 1)
printf '#!/bin/bash\necho "$*" >> "%s/lctl.log"\n[ "$1" = print-disabled ] && exit 5\nexit 0\n' "$T" > "$T/launchctl-broken"; chmod +x "$T/launchctl-broken"
: > "$T/lctl.log"; rm -f "$T/disabled"
out=$(LAUNCHCTL="$T/launchctl-broken" MAC_WINDOW_NOW=10:30 "$MW" catch-up); rc=$?
echo "$out" | grep -q "DISABLED_UNREADABLE" && [ "$rc" = 1 ] && ! grep -q kickstart "$T/lctl.log" && ok || no "fails closed when launchd is unreadable: rc=$rc $out"
echo '		"com.seq.t-paused" => disabled' > "$T/disabled"
# a pending job that is running right now is not started a second time
cat > "$T/launchctl-running" <<EOF2
#!/bin/bash
echo "\$*" >> "$T/lctl.log"
[ "\$1" = print-disabled ] && { echo 'disabled services = {'; echo '}'; exit 0; }
[ "\$1" = list ] && [ "\$2" = com.seq.t-busy ] && { echo '{'; echo '	"PID" = 4242;'; echo '};'; exit 0; }
exit 0
EOF2
chmod +x "$T/launchctl-running"
MAC_WINDOW_NOW=08:00 "$MW" run LIGHT com.seq.t-busy -- true >/dev/null
LAUNCHCTL="$T/launchctl-running" MAC_WINDOW_NOW=10:30 "$MW" catch-up | grep -q "PENDING_RUNNING com.seq.t-busy" && ! grep "kickstart" "$T/lctl.log" | grep -q t-busy && ok || no "running pending job started twice"
rm -f "$T/state/pending/com.seq.t-busy"
# an Eastern Mac: the plist says 07:20 local = 06:20 Central, so a 06:00 CT catch-up leaves it to its own slot
plist com.seq.t-east 7 20
MAC_WINDOW_NOW=05:00 "$MW" run LIGHT com.seq.t-east -- true >/dev/null
sed -i '' 's/"class": "LIGHT"/"class": "MORNING"/' "$T/state/pending/com.seq.t-east"
MAC_WINDOW_LOCAL_TZ=America/New_York MAC_WINDOW_NOW=06:00 "$MW" catch-up | grep -q "PENDING_LEFT com.seq.t-east" && ok || no "Eastern plist hour read as Central (double run)"
MAC_WINDOW_LOCAL_TZ=America/Chicago MAC_WINDOW_NOW=06:00 "$MW" catch-up --dry-run | grep -q "WOULD_START com.seq.t-east" && ok || no "NEGATIVE: on a Central Mac 07:20 is after the window, so it is started"
rm -f "$T/state/pending/com.seq.t-east"

# 6. Heavy slots: two 1-slot jobs run; a third interval tick is told the slots are busy and runs nothing.
MAC_WINDOW_NOW=23:00 MAC_WINDOW_STOP_IN=20 "$MW" run HEAVY com.seq.h1 -- sleep 3 & p1=$!
MAC_WINDOW_NOW=23:00 MAC_WINDOW_STOP_IN=20 MAC_WINDOW_SLOTS=1 "$MW" run HEAVY com.seq.h2 -- sleep 3 & p2=$!
sleep 1
out=$(MAC_WINDOW_NOW=23:00 "$MW" run HEAVY com.seq.pbs-library-fill --no-wait -- touch "$T/ran-pbs")
echo "$out" | grep -q "HEAVY_SLOTS_BUSY com.seq.pbs-library-fill" && [ ! -e "$T/ran-pbs" ] && ok || no "third heavy ran: $out"
# a calendar heavy job waits for a slot instead, then runs
MAC_WINDOW_NOW=23:00 MAC_WINDOW_WAIT_POLL=0.5 MAC_WINDOW_STOP_IN=20 "$MW" run HEAVY com.seq.h3 -- touch "$T/ran-h3" >/dev/null
[ -e "$T/ran-h3" ] && ok || no "waiting heavy job never ran"
wait $p1 $p2
# a 2-slot run (the PBS fill's two lanes) takes both slots: nothing else heavy starts beside it
MAC_WINDOW_NOW=23:00 MAC_WINDOW_STOP_IN=20 MAC_WINDOW_SLOTS=2 "$MW" run HEAVY com.seq.pbs-library-fill --no-wait -- sleep 3 & p3=$!
sleep 1
MAC_WINDOW_NOW=23:00 "$MW" run HEAVY com.seq.h4 --no-wait -- touch "$T/ran-h4" | grep -q HEAVY_SLOTS_BUSY && [ ! -e "$T/ran-h4" ] && ok || no "ran beside a 2-slot fill"
wait $p3

# 7. The 06:55 stop path: TERM reaches the job's process group, it saves its place and exits; the
#    guard reports a clean stop, frees the slot, and the next night's run resumes from the checkpoint.
cat > "$T/job.sh" <<EOF
#!/bin/bash
n=\$(cat "$T/ckpt" 2>/dev/null || echo 0)
trap 'echo \$n > "$T/ckpt"; echo saved > "$T/saved"; exit 0' TERM
while :; do n=\$((n+1)); sleep 0.2; done
EOF
chmod +x "$T/job.sh"
out=$(MAC_WINDOW_NOW=06:30 MAC_WINDOW_STOP_IN=1 "$MW" run HEAVY com.seq.t-stop -- "$T/job.sh"); rc=$?
echo "$out" | grep -q "STOPPING_AT_0655 com.seq.t-stop" && echo "$out" | grep -q "stopped cleanly" && [ "$rc" = 0 ] && ok || no "stop path: rc=$rc $out"
[ -e "$T/saved" ] && [ "$(cat "$T/ckpt")" -gt 0 ] && ok || no "job did not save its place"
[ ! -e "$T/state/heavy/com.seq.t-stop" ] && ok || no "slot not freed"
first=$(cat "$T/ckpt"); MAC_WINDOW_NOW=22:30 MAC_WINDOW_STOP_IN=1 "$MW" run HEAVY com.seq.t-stop -- "$T/job.sh" >/dev/null
[ "$(cat "$T/ckpt")" -gt "$first" ] && ok || no "next night did not resume from the checkpoint"
# the whole group: a backgrounded grandchild (a voice model the job started) gets TERM too
cat > "$T/parent.sh" <<EOF
#!/bin/bash
bash -c 'trap "echo gone > $T/grandchild-term; exit 0" TERM; while :; do sleep 0.2; done' &
wait
EOF
chmod +x "$T/parent.sh"
MAC_WINDOW_NOW=06:30 MAC_WINDOW_STOP_IN=1 MAC_WINDOW_KILL_AFTER=3 "$MW" run HEAVY com.seq.t-group -- "$T/parent.sh" >/dev/null
sleep 0.5; [ -e "$T/grandchild-term" ] && ok || no "grandchild never got TERM (process group not reached)"
# the 06:55 maths itself (no STOP_IN): 06:30:00 stops in 1500 s, 23:00:30 in 28470 s
MAC_WINDOW_NOW=06:30:00 "$MW" run HEAVY com.seq.t-maths -- true | grep -q "stops at 06:55 (in 1500 s)" && ok || no "06:30 stop maths"
MAC_WINDOW_NOW=23:00:30 "$MW" run HEAVY com.seq.t-maths -- true | grep -q "stops at 06:55 (in 28470 s)" && ok || no "23:00 stop maths"
# a job that ignores TERM is killed and named, never left running into the power-off
cat > "$T/stubborn.sh" <<'EOF'
#!/bin/bash
trap '' TERM; while :; do sleep 0.2; done
EOF
chmod +x "$T/stubborn.sh"
out=$(MAC_WINDOW_NOW=06:30 MAC_WINDOW_STOP_IN=1 MAC_WINDOW_KILL_AFTER=1 "$MW" run HEAVY com.seq.t-stub -- "$T/stubborn.sh"); rc=$?
echo "$out" | grep -q "KILLED_AT_WINDOW_END" && [ "$rc" = 75 ] && ok || no "stubborn job: rc=$rc $out"

# 8. The morning block: the first morning job before 07:00 raises the flag, it stays between morning jobs,
#    the last one (finishing at/after 06:14) clears it, and a flag left behind is swept from 06:55.
export MAC_WINDOW_MORNING_FLAG="$T/boss/morning-window.active"
MAC_WINDOW_NOW=03:40 "$MW" run MORNING com.seq.boss-credentials -- true | grep -q MORNING_BLOCK_ON && [ -e "$MAC_WINDOW_MORNING_FLAG" ] && ok || no "first morning job raises the flag"
MAC_WINDOW_NOW=04:05 "$MW" run MORNING com.seq.boss-agent -- sh -c "test -e '$MAC_WINDOW_MORNING_FLAG'" && [ -e "$MAC_WINDOW_MORNING_FLAG" ] && ok || no "flag held while a morning job runs and after it (more to come)"
MAC_WINDOW_NOW=10:30 "$MW" run MORNING com.seq.boss-morning-catchup -- true | grep -q MORNING_BLOCK_SWEPT && [ ! -e "$MAC_WINDOW_MORNING_FLAG" ] && ok || no "a flag left past 06:55 is swept by the next run"
MAC_WINDOW_NOW=06:14 "$MW" run MORNING com.seq.boss-morning-catchup -- true >/dev/null; touch "$MAC_WINDOW_MORNING_FLAG"
MAC_WINDOW_NOW=06:14 "$MW" run MORNING com.seq.boss-morning-catchup -- true | grep -q MORNING_BLOCK_OFF && [ ! -e "$MAC_WINDOW_MORNING_FLAG" ] && ok || no "last morning job clears the flag"
# two at once: the earlier one finishing past 06:14 does not clear it while the other still runs
MAC_WINDOW_NOW=06:20 "$MW" run MORNING com.seq.m-long -- sleep 2 & pl=$!
sleep 0.5
MAC_WINDOW_NOW=06:27 "$MW" run MORNING com.seq.m-short -- true >/dev/null
[ -e "$MAC_WINDOW_MORNING_FLAG" ] && ok || no "flag cleared while a morning job still ran"
wait $pl
touch "$MAC_WINDOW_MORNING_FLAG"; MAC_WINDOW_NOW=06:56 "$MW" run ANY com.seq.boss-runtime-sync -- true | grep -q MORNING_BLOCK_SWEPT && [ ! -e "$MAC_WINDOW_MORNING_FLAG" ] && ok || no "stale flag swept at 06:56"
touch "$MAC_WINDOW_MORNING_FLAG"; MAC_WINDOW_NOW=05:00 "$MW" run ANY com.seq.boss-runtime-sync -- true >/dev/null; [ -e "$MAC_WINDOW_MORNING_FLAG" ] && ok || no "flag swept inside the morning block"
touch -t "$(date -v-5H +%Y%m%d%H%M)" "$MAC_WINDOW_MORNING_FLAG"; MAC_WINDOW_NOW=05:00 "$MW" run ANY com.seq.boss-runtime-sync -- true | grep -q MORNING_BLOCK_SWEPT && ok || no "a flag older than 4 h is removed"

echo "test-mac-window: $pass passed, $fail failed"
[ "$fail" = 0 ] && [ "$pass" -ge 73 ]
