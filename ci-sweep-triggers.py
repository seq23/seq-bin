#!/usr/bin/env python3
"""Model whether a GitHub Actions workflow SHOULD have run.

WHY THIS EXISTS
---------------
ci-sweep-probe.sh decided a lane was SILENT by comparing "commits in the window"
against "runs in the window", and asked only one question about the workflow
file: does the string `push:` appear in it. That is not a trigger model, it is a
grep, and on 2026-09-09 it reported this, every single time it ran:

    local-guides-generator | Build Starter Pack | NEVER_RAN
        push-triggered workflow with no run on main despite 1 commit(s)

`Build Starter Pack` is healthy. It has runs on main, the newest a success. It
did not run that day because it carries a `paths:` filter over six paths, and
the day's only commit touched `CHANGELOG.md` and two files under
`data/signals/`. NOT RUNNING WAS THE CORRECT BEHAVIOUR.

A false SILENT is worse than a missed one, because it is UNCLEARABLE BY
CONSTRUCTION. The probe says main is not green; the wrapper dispatches an agent;
the agent cannot make a correctly-filtered workflow run; the probe says main is
not green. No work anybody can do changes the verdict. It ends in
MAIN-RED-EXHAUSTED over a healthy repo, having spent on it the budget the real
failures needed.

So the question is no longer "does this file mention push" but "given the files
actually changed on the default branch in this window, does this workflow's own
trigger configuration say it should have run". That question has a real answer,
and this computes it.

WHAT IS MODELLED
  · push triggers, with branches / branches-ignore / tags / tags-ignore
  · paths: and paths-ignore: filters, with GitHub's glob dialect (* ** ? ! ranges)
  · workflow_dispatch-only and workflow_call-only lanes (never automatic)
  · schedule-only lanes, including whether the cron actually came round in the
    window -- a nightly workflow at 14:00 is not silent, it is early
  · job-level `if:` gates: when every job is gated on an expression this cannot
    evaluate, the honest answer is UNKNOWN, and UNKNOWN must not be a finding

NO PYYAML ON THIS MACHINE, so the `on:` block is parsed here. The parser is
deliberately small and deliberately conservative: anything it does not fully
understand yields UNKNOWN, and UNKNOWN never produces a SILENT verdict. A
detector that guesses is the thing being replaced.

USAGE
    ci-sweep-triggers.py should-run --workflow FILE --branch main \
        --changed-files LISTFILE [--since ISO] [--until ISO]

    Prints one line:  YES|NO|UNKNOWN <tab> reason
    Exit 0 on a verdict, 2 if the workflow file could not be read.
"""

import argparse
import datetime as dt
import os
import re
import sys

# --------------------------------------------------------------------------
# A very small YAML subset parser.
#
# It handles what workflow trigger blocks are actually written in: nested
# mappings by indentation, block sequences, inline flow sequences, quoted
# scalars and comments. It SKIPS block scalars (`|`, `>`) rather than
# mis-parsing their contents as structure -- `run: |` bodies are shell, and a
# shell line beginning `- ` is not a YAML sequence item.
#
# Anything outside that subset raises, and every caller turns a raise into
# UNKNOWN rather than into a verdict.
# --------------------------------------------------------------------------


class ParseError(Exception):
    pass


def _strip_comment(s):
    """Remove a trailing # comment that is not inside quotes."""
    out, quote = [], None
    i = 0
    while i < len(s):
        c = s[i]
        if quote:
            out.append(c)
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
            out.append(c)
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out).rstrip()


def _scalar(tok):
    tok = tok.strip()
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'":
        return tok[1:-1]
    return tok


def _flow_seq(tok):
    """[a, b, 'c'] -> ['a','b','c']"""
    inner = tok.strip()[1:-1].strip()
    if not inner:
        return []
    parts, cur, quote, depth = [], [], None, 0
    for c in inner:
        if quote:
            cur.append(c)
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
            cur.append(c)
        elif c in "[{":
            depth += 1
            cur.append(c)
        elif c in "]}":
            depth -= 1
            cur.append(c)
        elif c == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    parts.append("".join(cur))
    return [_scalar(p) for p in parts if p.strip() != ""]


def _unbalanced(s):
    """Net depth of [ and { outside quotes -- used to join multi-line flow lists."""
    depth, quote = 0, None
    for c in s:
        if quote:
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
    return depth


def _lines(text):
    """Yield (indent, content) for structural lines, skipping block scalars.

    Flow collections that span several lines are joined back into one logical
    line first. how-we-know's `loop-tests.yml` writes its `paths:` list across
    three lines, and p-n-p's `deploy-distribution.yml` its `workflows:` list
    across two; parsing those line-by-line produced "not a mapping entry" and
    the whole workflow degraded to UNKNOWN.
    """
    raw = text.splitlines()
    joined = []
    i = 0
    while i < len(raw):
        line = raw[i]
        if _unbalanced(_strip_comment(line)) > 0:
            buf = line
            i += 1
            while i < len(raw) and _unbalanced(_strip_comment(buf)) > 0:
                buf = buf.rstrip() + " " + raw[i].strip()
                i += 1
            joined.append(buf)
            continue
        joined.append(line)
        i += 1
    raw = joined

    i = 0
    while i < len(raw):
        line = raw[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        if "\t" in line[:indent]:
            raise ParseError("tab indentation")
        content = _strip_comment(line.strip())
        if not content:
            i += 1
            continue
        # Block scalar: swallow every following line indented deeper.
        if re.search(r":\s*[|>][-+0-9]*$", content):
            key = content.split(":", 1)[0]
            yield (indent, key + ":")
            i += 1
            while i < len(raw):
                nxt = raw[i]
                if not nxt.strip():
                    i += 1
                    continue
                nind = len(nxt) - len(nxt.lstrip(" "))
                if nind <= indent:
                    break
                i += 1
            continue
        yield (indent, content)
        i += 1


def parse_yaml(text):
    """Parse the subset into nested dict/list. Raises ParseError on anything else."""
    items = list(_lines(text))
    pos = [0]

    def parse_block(indent):
        # Decide mapping vs sequence from the first line at this indent.
        if pos[0] >= len(items):
            return None
        _, first = items[pos[0]]
        if first.startswith("- "):
            return parse_seq(indent)
        if first == "-":
            return parse_seq(indent)
        return parse_map(indent)

    def parse_map(indent):
        out = {}
        while pos[0] < len(items):
            ind, content = items[pos[0]]
            if ind < indent:
                break
            if ind > indent:
                raise ParseError("unexpected indent %d (want %d): %r" % (ind, indent, content))
            if content.startswith("-"):
                break
            if ":" not in content:
                raise ParseError("not a mapping entry: %r" % content)
            key, _, rest = content.partition(":")
            key = _scalar(key)
            rest = rest.strip()
            pos[0] += 1
            if rest == "":
                # Nested block, or an empty value (`push:` with nothing under it).
                if pos[0] < len(items) and items[pos[0]][0] > indent:
                    # A flow sequence written on the line BELOW its key --
                    # p-n-p writes `workflows:` that way -- is still that key's
                    # value, not a new mapping entry.
                    if items[pos[0]][1].startswith("["):
                        out[key] = _flow_seq(items[pos[0]][1])
                        pos[0] += 1
                    else:
                        out[key] = parse_block(items[pos[0]][0])
                else:
                    out[key] = None
            elif rest.startswith("["):
                out[key] = _flow_seq(rest)
            elif rest.startswith("{"):
                # An inline flow mapping (`with: { node-version: 22 }`). Nothing in
                # a trigger block needs its contents, and raising here degraded five
                # of approvalprep's workflows to UNKNOWN over a `with:` line in a
                # step. Kept as an opaque scalar instead.
                out[key] = rest
            else:
                out[key] = _scalar(rest)
        return out

    def parse_seq(indent):
        out = []
        while pos[0] < len(items):
            ind, content = items[pos[0]]
            if ind < indent or not content.startswith("-"):
                break
            if ind > indent:
                raise ParseError("unexpected indent in sequence")
            rest = content[1:].strip()
            pos[0] += 1
            if rest == "":
                if pos[0] < len(items) and items[pos[0]][0] > indent:
                    out.append(parse_block(items[pos[0]][0]))
                else:
                    out.append(None)
            elif ":" in rest and not rest.startswith(("[", '"', "'")):
                # `- cron: '0 3 * * *'` -- an inline mapping opening a sequence item.
                key, _, val = rest.partition(":")
                entry = {}
                val = val.strip()
                if val.startswith("["):
                    entry[_scalar(key)] = _flow_seq(val)
                elif val == "":
                    entry[_scalar(key)] = None
                else:
                    entry[_scalar(key)] = _scalar(val)
                # Continuation keys of the same sequence item, indented deeper.
                while pos[0] < len(items) and items[pos[0]][0] > indent \
                        and not items[pos[0]][1].startswith("-"):
                    sub = parse_map(items[pos[0]][0])
                    entry.update(sub)
                out.append(entry)
            elif rest.startswith("["):
                out.append(_flow_seq(rest))
            else:
                out.append(_scalar(rest))
        return out

    result = parse_block(0)
    if pos[0] != len(items):
        raise ParseError("trailing content at %r" % (items[pos[0]],))
    return result


# --------------------------------------------------------------------------
# GitHub's path/branch glob dialect.
#
# `*` matches any character except `/`; `**` matches any character including
# `/`; `?` one character; `!` at the start negates; `+` and character ranges
# are passed through. Getting `**` wrong is the difference between
# `data/training/**` matching `data/signals/x.json` and not, which is the whole
# false positive.
# --------------------------------------------------------------------------


def glob_to_regex(pat):
    out = ["^"]
    i = 0
    while i < len(pat):
        c = pat[i]
        if c == "*":
            if pat[i:i + 2] == "**":
                out.append(".*")
                i += 2
                # `foo/**` should also match `foo/` prefixed paths; `.*` covers it.
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = pat.find("]", i)
            if j == -1:
                out.append(re.escape(c))
            else:
                out.append(pat[i:j + 1])
                i = j + 1
                continue
        else:
            out.append(re.escape(c))
        i += 1
    out.append("$")
    return re.compile("".join(out))


def _as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return [x for x in v if isinstance(x, str)]
    if isinstance(v, str):
        return [v]
    return []


def filter_matches(patterns, paths):
    """True if any path matches any (non-negated) pattern, honouring `!` negation
    in order, the way GitHub evaluates a filter list."""
    if not patterns:
        return True
    for p in paths:
        verdict = False
        for pat in patterns:
            neg = pat.startswith("!")
            body = pat[1:] if neg else pat
            if glob_to_regex(body).match(p):
                verdict = not neg
        if verdict:
            return True
    return False


def branch_matches(patterns, branch):
    if not patterns:
        return True
    verdict = False
    for pat in patterns:
        neg = pat.startswith("!")
        body = pat[1:] if neg else pat
        if glob_to_regex(body).match(branch):
            verdict = not neg
    return verdict


# --------------------------------------------------------------------------
# cron
# --------------------------------------------------------------------------


def _cron_field(field, lo, hi):
    vals = set()
    for part in field.split(","):
        step = 1
        if "/" in part:
            part, _, s = part.partition("/")
            step = int(s)
        if part in ("*", ""):
            start, end = lo, hi
        elif "-" in part:
            a, _, b = part.partition("-")
            start, end = int(a), int(b)
        else:
            start = end = int(part)
            if step == 1:
                vals.add(start)
                continue
        vals.update(range(start, end + 1, step))
    return vals


def cron_fired(expr, since, until):
    """Did this 5-field UTC cron come round between since and until?"""
    fields = expr.split()
    if len(fields) != 5:
        raise ParseError("cron does not have five fields: %r" % expr)
    minute = _cron_field(fields[0], 0, 59)
    hour = _cron_field(fields[1], 0, 23)
    dom = _cron_field(fields[2], 1, 31)
    month = _cron_field(fields[3], 1, 12)
    dow_raw = _cron_field(fields[4], 0, 7)
    dow = {0 if d == 7 else d for d in dow_raw}
    dom_restricted = fields[2] != "*"
    dow_restricted = fields[4] != "*"

    t = since.replace(second=0, microsecond=0)
    while t <= until:
        if t.minute in minute and t.hour in hour and t.month in month:
            # cron's OR rule when both day fields are restricted
            d_ok = t.day in dom
            w_ok = ((t.weekday() + 1) % 7) in dow
            if dom_restricted and dow_restricted:
                day_ok = d_ok or w_ok
            elif dom_restricted:
                day_ok = d_ok
            elif dow_restricted:
                day_ok = w_ok
            else:
                day_ok = True
            if day_ok:
                return True
        t += dt.timedelta(minutes=1)
    return False


# --------------------------------------------------------------------------
# the verdict
# --------------------------------------------------------------------------

YES, NO, UNKNOWN = "YES", "NO", "UNKNOWN"


def normalise_on(doc):
    """Return the `on:` mapping, whatever shape it was written in."""
    if not isinstance(doc, dict):
        raise ParseError("workflow is not a mapping")
    on = None
    for key in ("on", True, "True", "'on'", '"on"'):
        if key in doc:
            on = doc[key]
            break
    if on is None and "on" not in doc:
        raise ParseError("no `on:` block")
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on if isinstance(k, str)}
    if isinstance(on, dict):
        return on
    if on is None:
        raise ParseError("empty `on:` block")
    raise ParseError("unrecognised `on:` shape")


def all_jobs_gated(doc):
    """True when every job carries an `if:` this cannot evaluate.

    A workflow whose only job is `if: github.event_name == 'schedule'` will not
    do anything on a push even though the push trigger fired, so calling it
    silent would be another unclearable finding. Anything with at least one
    ungated job is treated as capable of running.
    """
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        return False
    for _, spec in jobs.items():
        if not isinstance(spec, dict):
            return False
        if "if" not in spec:
            return False
    return True


def _verdict_inner(text, branch, changed_files, since, until):
    doc = parse_yaml(text)
    on = normalise_on(doc)
    keys = set(on.keys())
    automatic = keys - {"workflow_dispatch", "workflow_call", "repository_dispatch"}
    if not automatic:
        return NO, "workflow_dispatch/workflow_call only — never triggered by a push"

    # --- push -------------------------------------------------------------
    if "push" in keys:
        cfg = on.get("push") or {}
        if not isinstance(cfg, dict):
            cfg = {}
        br = _as_list(cfg.get("branches"))
        br_ig = _as_list(cfg.get("branches-ignore"))
        tags = _as_list(cfg.get("tags")) + _as_list(cfg.get("tags-ignore"))
        paths = _as_list(cfg.get("paths"))
        paths_ig = _as_list(cfg.get("paths-ignore"))

        if tags and not br and not br_ig and "branches" not in cfg:
            # tag-only push trigger: a branch push does not fire it
            if not paths and not paths_ig:
                return NO, "push trigger is tag-scoped only"

        if br and not branch_matches(br, branch):
            return NO, "push `branches:` %s does not include %s" % (br, branch)
        if br_ig and branch_matches(br_ig, branch):
            return NO, "push `branches-ignore:` %s excludes %s" % (br_ig, branch)

        if not changed_files:
            return UNKNOWN, "no changed-file list available for the window"

        if paths:
            if filter_matches(paths, changed_files):
                return YES, "a changed file matches push `paths:` %s" % (paths,)
            return NO, ("push `paths:` filter (%d pattern(s)) matches none of the %d "
                        "file(s) changed in the window — not running was correct"
                        % (len(paths), len(changed_files)))
        if paths_ig:
            remaining = [p for p in changed_files
                         if not filter_matches(paths_ig, [p])]
            if remaining:
                return YES, "%d changed file(s) survive push `paths-ignore:`" % len(remaining)
            return NO, ("every file changed in the window is covered by push "
                        "`paths-ignore:` %s — not running was correct" % (paths_ig,))
        return YES, "unfiltered push trigger on %s and %d commit file(s) in the window" % (
            branch, len(changed_files))

    # --- schedule ---------------------------------------------------------
    if "schedule" in keys:
        entries = on.get("schedule") or []
        crons = []
        if isinstance(entries, list):
            for e in entries:
                if isinstance(e, dict) and "cron" in e:
                    crons.append(e["cron"])
        if not crons:
            return UNKNOWN, "schedule block present but no cron could be read"
        for c in crons:
            if cron_fired(c, since, until):
                return YES, "cron %r came round inside the window" % c
        return NO, "no cron in %r came round inside the window" % (crons,)

    # --- neither push nor schedule ---------------------------------------
    # `pull_request`, `release`, `workflow_run` and friends can produce runs, but
    # never as a consequence of a push to the default branch, which is the only
    # question this answers. Saying UNKNOWN here would leave a large, permanently
    # unresolvable grey area over lanes that are behaving correctly.
    return NO, ("no push or schedule trigger — %s does not fire on a push to %s"
                % (sorted(keys), branch))


def verdict(text, branch, changed_files, since, until):
    """Trigger verdict, with the job-gate check applied LAST.

    `all_jobs_gated` used to run first and swallowed twelve of the fleet's
    workflows into UNKNOWN before their triggers were even read -- including
    lanes whose triggers alone already gave a clean NO (workflow_run-driven
    distribution lanes, for one). A gate can only turn a YES into an UNKNOWN; it
    can never turn a NO into a finding, so it belongs after the trigger answer,
    not before it.
    """
    v, why = _verdict_inner(text, branch, changed_files, since, until)
    if v == YES:
        try:
            if all_jobs_gated(parse_yaml(text)):
                return UNKNOWN, ("%s, but every job carries an `if:` gate this "
                                 "cannot evaluate" % why)
        except ParseError:
            pass
    return v, why


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("should-run")
    r.add_argument("--workflow", required=True)
    r.add_argument("--branch", default="main")
    r.add_argument("--changed-files", default="")
    r.add_argument("--since", default="")
    r.add_argument("--until", default="")
    args = ap.parse_args()

    try:
        with open(args.workflow, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        # Not readable is not the same as not triggered. UNKNOWN, so the caller
        # cannot turn a missing checkout into a SILENT finding.
        print("UNKNOWN\tworkflow file unreadable: %s" % exc)
        return 2

    changed = []
    if args.changed_files and os.path.exists(args.changed_files):
        with open(args.changed_files, "r", encoding="utf-8", errors="replace") as fh:
            changed = [l.strip() for l in fh if l.strip()]

    def iso(s, default):
        if not s:
            return default
        return dt.datetime.strptime(s.replace("Z", ""), "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=dt.timezone.utc)

    now = dt.datetime.now(dt.timezone.utc)
    until = iso(args.until, now)
    since = iso(args.since, until - dt.timedelta(hours=14))

    try:
        v, why = verdict(text, args.branch, changed, since, until)
    except ParseError as exc:
        # THE PARSER FAILING MUST NEVER PRODUCE A FINDING. An unclearable SILENT
        # born of a parse error is the same defect as the one this replaces.
        v, why = UNKNOWN, "trigger block not understood (%s)" % exc
    except Exception as exc:  # noqa: BLE001 - any parser surprise degrades to UNKNOWN, never to a finding
        v, why = UNKNOWN, "trigger model error (%s)" % exc

    print("%s\t%s" % (v, why))
    return 0


if __name__ == "__main__":
    sys.exit(main())
