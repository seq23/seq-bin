#!/bin/bash
# Wires the dangerous-command guard (command-guard.mjs) into Claude Code and Codex as a PreToolUse hook.
# Idempotent: an entry already pointing at command-guard.mjs is left as it is; every other setting and hook
# in both files is kept. Proves the guard first (--self-test) and refuses to wire a guard that fails it.
#
#   ~/bin/install-command-guard.sh            # ~/.claude/settings.json and ~/.codex/hooks.json
#   ~/bin/install-command-guard.sh --check    # say whether both are wired; change nothing (exit 1 if not)
#
# GUARD_HOME exists for tests/test-command-guard.sh only.
set -euo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="${GUARD_HOME:-$HOME}"
GUARD="$BIN/command-guard.mjs"
node "$GUARD" --self-test >/dev/null || { echo "NAMED STOP [GUARD_SELF_TEST_FAILED] the guard failed its own self-test; nothing wired." >&2; exit 1; }
node --input-type=module - "$H" "$GUARD" "${1:-}" <<'JS'
import fs from "node:fs"; import path from "node:path";
const [home, guard, mode] = process.argv.slice(2);
const command = `node ${guard}`;
// Claude Code: settings.json, matcher Bash. Codex: hooks.json, same shape; it names its shell tool Bash too,
// so no matcher (every tool) is used there and the guard ignores a call that carries no command.
const targets = [
  { file: path.join(home, ".claude", "settings.json"), entry: { matcher: "Bash", hooks: [{ type: "command", command, timeout: 10 }] } },
  { file: path.join(home, ".codex", "hooks.json"), entry: { hooks: [{ type: "command", command, timeout: 10 }] } },
];
let missing = 0;
for (const { file, entry } of targets) {
  let cfg = {};
  if (fs.existsSync(file)) cfg = JSON.parse(fs.readFileSync(file, "utf8"));
  const pre = ((cfg.hooks ??= {}).PreToolUse ??= []);
  const wired = pre.some((e) => (e.hooks ?? []).some((h) => String(h.command ?? "").includes("command-guard.mjs")));
  if (mode === "--check") { console.log(`${wired ? "wired" : "NOT wired"}: ${file}`); if (!wired) missing++; continue; }
  if (wired) { console.log(`already wired: ${file}`); continue; }
  pre.push(entry);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.guard-tmp`;
  fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2) + "\n");
  fs.renameSync(tmp, file);
  console.log(`wired: ${file}`);
}
process.exit(missing ? 1 : 0);
JS
