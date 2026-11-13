# shellcheck shell=bash
# A failed tail check is counted; a tail that cannot check is down, and she is told (13 Nov 2026:
# 332 checks failed over 3.5 days with only a log line, and a partner email went untailed).
# check_failed <count-file> <alert-fn>: adds one; at the 4th in a row (an hour of 15-min ticks) and
#   every 96th after that (once a day) calls <alert-fn> <count>.
# check_ok <count-file>: a check that worked clears the count.
check_failed() {
  local file="$1" alert="$2" n
  n="$(cat "$file" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n+1)); echo "$n" > "$file"
  echo "[watch] failed check $n in a row"
  if [ "$n" -eq 4 ] || { [ "$n" -gt 4 ] && [ $(((n-4) % 96)) -eq 0 ]; }; then "$alert" "$n"; fi
}
check_ok() { rm -f "$1"; }
