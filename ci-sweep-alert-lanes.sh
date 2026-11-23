#!/bin/bash
# GitHub's own security findings on the Divine 10 repos, as lanes the CI sweep works (23 Nov 2026).
#
# WHY THIS EXISTS
# Her words, 23 Nov 2026: "every repo that is a divine 10 business should get locked down and an
# audit". CodeQL, secret scanning and Dependabot now run on all 12 repos in ci-sweep-security.json,
# and on that day they held 351 open code-scanning alerts, 1 leaked key and 328 vulnerable
# dependencies that nothing read. An alert nobody reads is the same as no scanner. The sweep's
# probe already turns red CI into fix work; this turns each open alert set into a RED lane in the
# same brief, and checks that the main-branch ruleset in the same file is still live.
#
# INPUT  $CI_SWEEP_SECURITY_CONFIG (default: ci-sweep-security.json beside this script)
# OUTPUT the probe's lane format: STATE \t repo \t workflow \t signature \t detail
#        per repo: "security: code-scanning", "security: secret-scanning", "security: dependabot",
#        and, for protect=true, "security: ruleset".
#        RED     open alerts; the scanner is off or refuses us (403/404); CodeQL has no completed
#                analysis; the ruleset is missing a rule. Each names its stop in the signature.
#        GREEN   zero open alerts READ from GitHub (and, for code scanning, at least one analysis).
#        PENDING GitHub did not answer (rate limit, 5xx, network, a non-list reply): UNKNOWN, never
#                "0 alerts". The probe counts it as not green.
#        The detail never says "run #N", so FIXED-UNVERIFIED never tries to dispatch an alert.
#        A secret's value is never read into a lane: only its type, number and URL.
# ENV    CI_SWEEP_ONLY_REPOS restricts to those bare repo names, as the probe does.
# EXIT   0 normally; 3 NAMED STOP when the config is missing, unreadable or lists no repos
#        (zero repos read is not a clean bill of health).
set -uo pipefail
CONFIG="${CI_SWEEP_SECURITY_CONFIG:-$(cd "$(dirname "$0")" && pwd)/ci-sweep-security.json}"
ONLY_REPOS="${CI_SWEEP_ONLY_REPOS:-}"
SHOW="${CI_SWEEP_ALERTS_SHOWN:-8}"

if ! repos="$(jq -r '.repos[] | "\(.repo)\t\(.protect)"' "$CONFIG" 2>/dev/null)" || [ -z "$repos" ]; then
  echo "NAMED STOP [NO_SECURITY_CONFIG] $CONFIG is missing, unreadable or lists no repos; the Divine 10 alerts would be read by nothing." >&2
  exit 3
fi
want_rules="$(jq -r '[.ruleset.rules[].type]|sort|join(",")' "$CONFIG" 2>/dev/null)"
rs_name="$(jq -r '.ruleset.name' "$CONFIG" 2>/dev/null)"

# One GitHub read. Prints the JSON (all pages merged) on success. On failure prints a stop name:
#   RATE_LIMITED / UNREADABLE  -> unknown (PENDING)
#   OFF_OR_NO_ACCESS           -> the feature is off or we may not read it (RED)
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
read_api() { # <path> [--paginate]
  local path="$1" out err rc
  if [ "${2:-}" = "--paginate" ]; then
    gh api --paginate --slurp "$path" >"$TMPD/out" 2>"$TMPD/err" </dev/null; rc=$?
  else
    gh api "$path" >"$TMPD/out" 2>"$TMPD/err" </dev/null; rc=$?
  fi
  out="$(cat "$TMPD/out")"; err="$(cat "$TMPD/err")"
  if [ "$rc" -eq 0 ]; then
    if [ "${2:-}" = "--paginate" ]; then
      printf '%s' "$out" | jq -ce 'if type=="array" and all(.[]; type=="array") then add // [] else error end' 2>/dev/null && return 0
    else
      printf '%s' "$out" | jq -ce '.' 2>/dev/null && return 0
    fi
    echo "UNREADABLE"; return 1
  fi
  if printf '%s %s' "$out" "$err" | grep -qiE 'rate limit|HTTP 429'; then echo "RATE_LIMITED"; return 1; fi
  if printf '%s' "$err" | grep -qE 'HTTP (401|403|404|410)'; then echo "OFF_OR_NO_ACCESS"; return 1; fi
  echo "UNREADABLE"; return 1
}

# A stop on a read becomes a lane: unknown is PENDING, off/refused is RED. Never GREEN.
stop_lane() { # <repo> <kind> <stop>
  local bare="$1" kind="$2" stop="$3"
  case "$stop" in
    OFF_OR_NO_ACCESS)
      printf 'RED\t%s\tsecurity: %s\t%s|security|%s|SCANNING_OFF_OR_NO_ACCESS\tNAMED STOP [SCANNING_OFF_OR_NO_ACCESS] GitHub refused the %s read (403/404): the scanner is off or this token cannot read it. Turn it back on as ci-sweep-security.json says; if the token lacks the right, PARK the repo naming it. Not clean: unread.\n' "$bare" "$kind" "$bare" "$kind" "$kind" ;;
    RATE_LIMITED)
      printf 'PENDING\t%s\tsecurity: %s\t%s|security|%s|ALERTS_RATE_LIMITED\tNAMED STOP [ALERTS_RATE_LIMITED] GitHub rate-limited the %s read; unknown, not 0 alerts.\n' "$bare" "$kind" "$bare" "$kind" "$kind" ;;
    *)
      printf 'PENDING\t%s\tsecurity: %s\t%s|security|%s|ALERTS_UNREADABLE\tNAMED STOP [ALERTS_UNREADABLE] GitHub did not answer the %s read (5xx, network or a reply that is not a list); unknown, not 0 alerts.\n' "$bare" "$kind" "$bare" "$kind" "$kind" ;;
  esac
}

sig_of() { jq -r '[.[].number]|sort|map(tostring)|join(",")' | cksum | cut -d' ' -f1; }

while IFS=$'\t' read -r full protect; do
  bare="${full#*/}"
  [ -n "$bare" ] || continue
  if [ -n "$ONLY_REPOS" ]; then case " $ONLY_REPOS " in *" $bare "*) ;; *) continue ;; esac; fi
  tab="https://github.com/$full/security"

  # --- code scanning: an empty or missing analysis list is NOT "no alerts" ---------------------
  if an="$(read_api "repos/$full/code-scanning/analyses?per_page=1")" && [ "$(printf '%s' "$an" | jq 'if type=="array" then length else 0 end')" -gt 0 ]; then
    if al="$(read_api "repos/$full/code-scanning/alerts?state=open&per_page=100" --paginate)"; then
      n="$(printf '%s' "$al" | jq length)"
      if [ "$n" -eq 0 ]; then
        printf 'GREEN\t%s\tsecurity: code-scanning\t%s|security|code-scanning|0\t0 open code-scanning alerts (CodeQL has analysed main)\n' "$bare" "$bare"
      else
        sev="$(printf '%s' "$al" | jq -r '[.[]|(.rule.security_severity_level // .rule.severity // "unknown")]|group_by(.)|map("\(length) \(.[0])")|join(", ")')"
        top="$(printf '%s' "$al" | jq -r --argjson k "$SHOW" '[.[]|"#\(.number) \(.rule.id) \(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)"][:$k]|join("; ")')"
        printf 'RED\t%s\tsecurity: code-scanning\t%s|security|code-scanning|%s|%s\t%s open code-scanning alerts (%s): %s. All: %s/code-scanning. Fix the code; an alert closes when CodeQL re-analyses main. Never dismiss an alert or switch a query off: that is weakening a check.\n' \
          "$bare" "$bare" "$n" "$(printf '%s' "$al" | sig_of)" "$n" "$sev" "$top" "$tab"
      fi
    else
      stop_lane "$bare" code-scanning "$al"
    fi
  else
    if [ -n "${an:-}" ] && printf '%s' "$an" | grep -qE '^(RATE_LIMITED|UNREADABLE)$'; then
      stop_lane "$bare" code-scanning "$an"
    else
      printf 'RED\t%s\tsecurity: code-scanning\t%s|security|code-scanning|NO_CODEQL_ANALYSIS\tNAMED STOP [NO_CODEQL_ANALYSIS] CodeQL has no completed analysis on this repo, or GitHub refused the analyses read (403/404), so 0 alerts would mean nothing. Turn default setup on (gh api -X PATCH repos/%s/code-scanning/default-setup -f state=configured) and confirm an analysis completes.\n' "$bare" "$bare" "$full"
    fi
  fi
  an=""

  # --- secret scanning: type, number and URL only; the secret itself never enters a lane -------
  if al="$(read_api "repos/$full/secret-scanning/alerts?state=open&per_page=100" --paginate)"; then
    n="$(printf '%s' "$al" | jq length)"
    if [ "$n" -eq 0 ]; then
      printf 'GREEN\t%s\tsecurity: secret-scanning\t%s|security|secret-scanning|0\t0 open secret-scanning alerts\n' "$bare" "$bare"
    else
      top="$(printf '%s' "$al" | jq -r --argjson k "$SHOW" '[.[]|"#\(.number) \(.secret_type_display_name // .secret_type)\(if .publicly_leaked then " (publicly leaked)" else "" end) \(.html_url)"][:$k]|join("; ")')"
      printf 'RED\t%s\tsecurity: secret-scanning\t%s|security|secret-scanning|%s|%s\t%s open secret-scanning alerts: %s. The key must be revoked at its vendor, which needs her account: work the repo'"'"'s other lanes first, then PARK it naming the key type and alert number. Never resolve the alert while the key may still work, and never print or commit the secret.\n' \
        "$bare" "$bare" "$n" "$(printf '%s' "$al" | sig_of)" "$n" "$top"
    fi
  else
    stop_lane "$bare" secret-scanning "$al"
  fi

  # --- Dependabot ---------------------------------------------------------------------------
  if al="$(read_api "repos/$full/dependabot/alerts?state=open&per_page=100" --paginate)"; then
    n="$(printf '%s' "$al" | jq length)"
    if [ "$n" -eq 0 ]; then
      printf 'GREEN\t%s\tsecurity: dependabot\t%s|security|dependabot|0\t0 open Dependabot alerts\n' "$bare" "$bare"
    else
      sev="$(printf '%s' "$al" | jq -r '[.[]|(.security_advisory.severity // "unknown")]|group_by(.)|map("\(length) \(.[0])")|join(", ")')"
      top="$(printf '%s' "$al" | jq -r --argjson k "$SHOW" '[.[]|"#\(.number) \(.dependency.package.name) \(.security_advisory.severity) in \(.dependency.manifest_path)\(if .security_vulnerability.first_patched_version.identifier then " (fixed in \(.security_vulnerability.first_patched_version.identifier))" else " (no fix yet)" end)"][:$k]|join("; ")')"
      printf 'RED\t%s\tsecurity: dependabot\t%s|security|dependabot|%s|%s\t%s open Dependabot alerts (%s): %s. All: %s/dependabot. Bump to the fixed version (lockfile too) and run the repo'"'"'s tests; an alert closes when main has the fix. One with no fix yet: drop or replace the package if the code allows, else leave it (never dismiss it) and name it in the report.\n' \
        "$bare" "$bare" "$n" "$(printf '%s' "$al" | sig_of)" "$n" "$sev" "$top" "$tab"
    fi
  else
    stop_lane "$bare" dependabot "$al"
  fi

  # --- the main-branch ruleset, as ci-sweep-security.json defines it --------------------------
  [ "$protect" = "true" ] || continue
  if br="$(read_api "repos/$full")" && br="$(printf '%s' "$br" | jq -r '.default_branch // empty')" && [ -n "$br" ] \
     && rl="$(read_api "repos/$full/rules/branches/$br")"; then
    have="$(printf '%s' "$rl" | jq -r '[.[].type]|unique|join(",")')"
    missing="$(jq -rn --arg w "$want_rules" --arg h "$have" '($w|split(",")) - ($h|split(","))|join(",")')"
    if [ -z "$missing" ]; then
      printf 'GREEN\t%s\tsecurity: ruleset\t%s|security|ruleset|OK\t%s has %s\n' "$bare" "$bare" "$br" "$want_rules"
    else
      printf 'RED\t%s\tsecurity: ruleset\t%s|security|ruleset|MISSING:%s\tNAMED STOP [RULESET_MISSING] %s lacks %s. Re-create the ruleset "%s" exactly as ci-sweep-security.json .ruleset says (gh api -X POST repos/%s/rulesets --input <(jq .ruleset ~/bin/ci-sweep-security.json)); never add a person as a bypass.\n' \
        "$bare" "$bare" "$missing" "$br" "$missing" "$rs_name" "$full"
    fi
  else
    stop_lane "$bare" ruleset "${rl:-${br:-UNREADABLE}}"
  fi
  br=""; rl=""
done <<< "$repos"
exit 0
