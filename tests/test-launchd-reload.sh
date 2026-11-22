#!/bin/bash
# launchd-reload: a disabled job stays disabled AND loaded (never booted out into nothing), a running
# job is not killed, a YouTube job held for the PBS fill is not loaded, an idle enabled job is reloaded,
# a reload that fails puts the old schedule back (never a missing job), and --pending applies the
# deferred ones once they can be, without touching the pause. A fake launchctl that behaves like
# launchd's refusal to bootstrap a disabled label (CONFIRMED 21 Nov 2026: "Bootstrap failed: 5").
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export LAUNCH_AGENTS_DIR="$T/agents" LAUNCHD_RELOAD_STATE="$T/state" LAUNCHCTL="$T/launchctl" PBS_FILL_FILE="$T/fill"
mkdir -p "$T/agents" "$T/ld/loaded" "$T/ld/disabled" "$T/ld/running"
cat > "$T/launchctl" <<EOF
#!/bin/bash
L="$T/ld"; echo "\$*" >> "$T/calls.log"
case "\$1" in
  print) l="\${2##*/}"; [ -f "\$L/loaded/\$l" ] ;;
  print-disabled) echo '{'; for f in "\$L"/disabled/*; do [ -f "\$f" ] && echo "	\"\$(basename "\$f")\" => disabled"; done; echo '}' ;;
  list) for f in "\$L"/loaded/*; do [ -f "\$f" ] || continue; l=\$(basename "\$f"); if [ -f "\$L/running/\$l" ]; then echo "123 0 \$l"; else echo "- 0 \$l"; fi; done ;;
  bootout) l="\${2##*/}"; [ -f "\$L/loaded/\$l" ] && rm "\$L/loaded/\$l" ;;
  bootstrap) l=\$(basename "\$3" .plist); [ -f "\$L/disabled/\$l" ] && { echo "Bootstrap failed: 5" >&2; exit 5; }
             grep -q REFUSE "\$3" && { echo "Bootstrap failed: 5" >&2; exit 5; }
             cp "\$3" "\$L/loaded/\$l" ;;
  enable|disable|kickstart) echo "FORBIDDEN \$*" >> "$T/forbidden.log" ;;
esac
EOF
chmod +x "$T/launchctl"
pass=0; fail=0
ok() { pass=$((pass+1)); }
no() { fail=$((fail+1)); echo "FAIL: $*"; }
mk() {  # label hour [extra]
  cat > "$T/agents/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$1</string><key>ProgramArguments</key><array><string>/usr/bin/true</string><string>${3:-}</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>$2</integer><key>Minute</key><integer>0</integer></dict></dict></plist>
EOF
}
loaded_hour() { plutil -extract StartCalendarInterval.Hour raw -o - "$T/ld/loaded/$1"; }
for l in com.seq.idle com.seq.off com.seq.busy com.howweknow.backfill com.seq.bad; do mk "$l" 8; cp "$T/agents/$l.plist" "$T/ld/loaded/$l"; done
touch "$T/ld/disabled/com.seq.off" "$T/ld/running/com.seq.busy" "$T/fill"
"$HERE/launchd-reload" --seed | grep -q "5 last-good" && ok || no "seed"
# the installers write the new versions (08:00 -> 10:00)
for l in com.seq.idle com.seq.off com.seq.busy com.howweknow.backfill; do mk "$l" 10; done
mk com.seq.bad 10 REFUSE
out=$("$HERE/launchd-reload" "$T"/agents/*.plist); rc=$?
echo "$out" | grep -q "RELOADED com.seq.idle" && [ "$(loaded_hour com.seq.idle)" = 10 ] && ok || no "idle job reloaded: $out"
echo "$out" | grep -q "DEFERRED_DISABLED com.seq.off" && [ -f "$T/ld/loaded/com.seq.off" ] && [ "$(loaded_hour com.seq.off)" = 8 ] && [ -f "$T/ld/disabled/com.seq.off" ] && ok || no "disabled job kept loaded, disabled, old schedule"
echo "$out" | grep -q "DEFERRED_RUNNING com.seq.busy" && [ "$(loaded_hour com.seq.busy)" = 8 ] && ok || no "running job untouched"
echo "$out" | grep -q "DEFERRED_PAUSED com.howweknow.backfill" && [ "$(loaded_hour com.howweknow.backfill)" = 8 ] && ok || no "YouTube job not reloaded while the fill holds it"
echo "$out" | grep -q "RELOAD_FAILED com.seq.bad" && [ -f "$T/ld/loaded/com.seq.bad" ] && [ "$(loaded_hour com.seq.bad)" = 8 ] && ! grep -q REFUSE "$T/agents/com.seq.bad.plist" && ok || no "failed reload restored the old schedule: $out"
[ "$rc" = 1 ] && ok || no "a failed reload exits 1 (rc=$rc)"
[ "$(ls "$T/ld/loaded" | wc -l | tr -d ' ')" = 5 ] && ok || no "same number of loaded jobs before and after"
[ ! -e "$T/forbidden.log" ] && ok || no "enable/disable/kickstart was called: $(cat "$T/forbidden.log")"
# nothing can be applied yet: all still waiting
"$HERE/launchd-reload" --pending | grep -q "0 of 3 applied" && ok || no "pending applied too early"
[ -f "$T/ld/disabled/com.seq.off" ] && ok || no "pending changed a pause"
# the pause ends (her planned enable), the run finishes, the fill finishes -> applied, once
rm "$T/ld/disabled/com.seq.off" "$T/ld/running/com.seq.busy" "$T/fill"
out=$("$HERE/launchd-reload" --pending)
echo "$out" | grep -q "3 of 3 applied" && [ "$(loaded_hour com.seq.off)" = 10 ] && [ "$(loaded_hour com.seq.busy)" = 10 ] && [ "$(loaded_hour com.howweknow.backfill)" = 10 ] && ok || no "pending applied: $out"
"$HERE/launchd-reload" --pending | grep -q "0 of 0 applied" && ok || no "pending empties"
[ ! -e "$T/forbidden.log" ] && ok || no "pending enabled/kickstarted something"
echo "test-launchd-reload: $pass passed, $fail failed"
[ "$fail" = 0 ] && [ "$pass" -ge 14 ]
