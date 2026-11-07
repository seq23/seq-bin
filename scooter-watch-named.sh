# shellcheck shell=bash
# named_ref <subject> <refs-file>: prints the first ref from <refs-file> (one per line, # comments ok)
# that <subject> carries, or nothing. A named job is tailed end to end, her own replies included
# (her words 7 Nov 2026: "put a tail on this pinecone job so u tail it goin forward").
named_ref() {
  local subject="$1" file="$2" r
  [ -s "$file" ] || return 0
  while IFS= read -r r || [ -n "$r" ]; do
    r="${r%%#*}"; r="$(printf '%s' "$r" | tr -d '[:space:]')"
    [ -n "$r" ] || continue
    if printf '%s' "$subject" | grep -qF "$r"; then printf '%s' "$r"; return 0; fi
  done < "$file"
}
