#!/usr/bin/env node
// THE DANGEROUS-COMMAND GUARD (owner, 19 Nov 2026, phase 1 of the veteran quality bar). A PreToolUse hook for
// Claude Code (~/.claude/settings.json) and Codex (~/.codex/hooks.json), wired by install-command-guard.sh.
// It reads the hook's JSON on stdin and refuses, with the reason, a shell command that cannot be undone:
//
//   rm -r / -rf      anything outside scratch (/tmp, $TMPDIR, /var/folders), an agent worktree (~/GitHub/.wt-*,
//                    ~/.boss-os/repo-change/wt-*), or a rebuildable folder (node_modules, dist, .next, …);
//                    a target it cannot see (a $VARIABLE, a backtick) is refused too; any rm of a com.seq.*
//                    launchd plist
//   git push         a force push (or a delete) that lands on main/master, named or as the current branch
//   git reset --hard / git clean -f / git checkout -- . / git restore .   in her own checkout with unsaved work
//   wrangler         deploy / publish / versions deploy outside the repo's deploy script (`land`, `npm run deploy…`);
//                    d1 execute --remote with DROP / DELETE / TRUNCATE; d1 delete / time-travel restore;
//                    deleting a Worker, a KV namespace, an R2 bucket or a queue
//   launchctl        unload / bootout / remove / disable of a com.seq.* job
//   gh repo delete; security delete-*-password; diskutil erase*
//   gh pr create     a PR that changes a function a fix changed in the last 30 days, with no
//                    `Patch or rebuild:` line naming that fix (her ruling 23 Nov 2026: asked when the PR opens,
//                    not at merge; land's own check, run by ~/bin/pr-patch-check). Could not judge: let through.
//
// These are hard safety stops, so they are code (CLAUDE.md: "code handles structure and hard safety stops").
// The hook runs only on an agent's own commands: the repos' scripts (land, deploy scripts, installers) run
// these commands inside themselves and are not seen. She can always run a refused command in her own
// Terminal. A hook input it cannot parse is let through with a note on stderr (a broken guard must not stop
// every session); `--self-test` proves every rule still refuses and a harmless command still passes.
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { basename, isAbsolute, resolve } from "node:path";
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HOME = homedir();

/** Split a command line into simple commands (argv arrays), honouring quotes; `bash -c "…"` is opened. */
export function commands(line) {
  const out = [];
  let argv = [], cur = "", has = false, q = null;
  const word = () => { if (has) argv.push(cur); cur = ""; has = false; };
  const end = () => { word(); if (argv.length) out.push(argv); argv = []; };
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === q) q = null;
      else if (c === "\\" && q === '"' && i + 1 < line.length) cur += line[++i];
      else cur += c;
      continue;
    }
    if (c === "'" || c === '"') { q = c; has = true; continue; }
    if (c === "\\" && i + 1 < line.length) { cur += line[++i]; has = true; continue; }
    if (c === " " || c === "\t") { word(); continue; }
    if (c === "\n" || c === ";" || c === "|" || c === "&" || c === "(" || c === ")" || c === "{" || c === "}") { end(); continue; }
    if (c === "$" && line[i + 1] === "(") { end(); i++; continue; }
    cur += c; has = true;
  }
  end();
  // Leading noise: VAR=x, sudo, env, command, nohup, time, exec, xargs; and shells running a string.
  const opened = [];
  for (let a of out) {
    while (a.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(a[0]) || ["sudo", "env", "command", "nohup", "time", "exec", "xargs", "then", "do", "else", "!"].includes(a[0]))) a = a.slice(1);
    if (!a.length) continue;
    const sh = basename(a[0]);
    const ci = a.findIndex((x) => /^-[a-z]*c[a-z]*$/.test(x));
    if (["bash", "sh", "zsh"].includes(sh) && ci > 0 && a[ci + 1]) { opened.push(...commands(a[ci + 1])); continue; }
    opened.push(a);
  }
  return opened;
}

const SCRATCH = () => [
  "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/",
  ...(process.env.TMPDIR ? [resolve(process.env.TMPDIR) + "/"] : []),
  `${HOME}/Library/Caches/`,
];
const REBUILDABLE = new Set(["node_modules", "dist", "build", "out", ".next", ".turbo", "coverage", ".cache", "test-results",
  "playwright-report", ".wrangler", "__pycache__", ".pytest_cache", ".mypy_cache", ".parcel-cache", "DerivedData", ".venv", "venv"]);

/** Expand ~ and $HOME; null when the path holds anything else the shell would fill in. */
function expand(p) {
  let s = p.replace(/^~(?=\/|$)/, HOME).replace(/\$\{?HOME\}?/g, HOME);
  if (/[$`]/.test(s)) return null;
  return s;
}

/** Why removing this path cannot be undone, or null when it is safe. */
export function rmTargetProblem(target, cwd) {
  const e = expand(target);
  if (e === null) return `it removes "${target}", and the guard cannot see where that points; write the path out`;
  const glob = e.search(/[*?[]/);
  const literal = glob === -1 ? e : e.slice(0, glob).replace(/[^/]*$/, "");
  const abs = resolve(isAbsolute(literal) ? literal : resolve(cwd, literal || "."));
  const full = glob === -1 ? abs : abs + "/*";
  if (/\/Library\/LaunchAgents\/com\.seq\./.test(full)) return `it deletes a com.seq.* launchd job (${full}); install or retire jobs with ~/bin/install-launchd.sh or the repo's installer`;
  if (glob === -1 && REBUILDABLE.has(basename(abs)) && abs.split("/").length > 3) return null;
  const inside = (root) => (abs + "/").startsWith(root) && abs + "/" !== root;
  if (SCRATCH().some(inside)) return null;
  if (abs.startsWith(`${HOME}/GitHub/.wt-`)) return null;
  if (abs.startsWith(`${HOME}/.boss-os/repo-change/wt-`)) return null;
  return `it recursively deletes ${full}, which is outside scratch (/tmp, $TMPDIR) and the agent worktrees (~/GitHub/.wt-*); that cannot be undone`;
}

const isMain = (b) => /^(refs\/heads\/)?(main|master)$/.test(b);

/** The current branch of a checkout, or "" when it cannot be read. */
function branchOf(dir) {
  try { return execFileSync("git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 3000 }).trim(); }
  catch { return ""; }
}
/** Unsaved work in a checkout ("" when clean or unreadable). */
function dirtyOf(dir) {
  try { return execFileSync("git", ["-C", dir, "status", "--porcelain"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000 }).trim(); }
  catch { return ""; }
}

function gitProblem(a, cwd, env) {
  let i = 1, dir = cwd;
  while (i < a.length && a[i].startsWith("-")) { if (a[i] === "-C") { dir = resolve(cwd, expand(a[i + 1] ?? ".") ?? "."); i += 2; } else if (a[i] === "-c") i += 2; else i++; }
  const sub = a[i], rest = a.slice(i + 1);
  if (sub === "push") {
    const force = rest.some((x) => /^(-f|--force|--force-with-lease(=.*)?|--force-if-includes|--mirror)$/.test(x) || /^-[a-zA-Z]*f[a-zA-Z]*$/.test(x));
    const del = rest.some((x) => x === "-d" || x === "--delete");
    const pos = rest.filter((x) => !x.startsWith("-"));
    const specs = pos.slice(1);
    const dsts = specs.map((s) => s.replace(/^\+/, "")).map((s) => (s.includes(":") ? s.split(":").pop() : s));
    if (specs.some((s) => s.startsWith("+") && isMain(s.replace(/^\+/, "").split(":").pop()))) return "it force-pushes to main; main's history is shared and a force push loses commits. Open a PR and land it";
    if (specs.some((s) => s.startsWith(":") && isMain(s.slice(1))) || (del && dsts.some(isMain))) return "it deletes main on the remote";
    if (force) {
      const targets = dsts.length ? dsts : [env.branchOf(dir)];
      if (targets.some(isMain)) return "it force-pushes to main; main's history is shared and a force push loses commits. Open a PR and land it";
    }
    return null;
  }
  const destroys = (sub === "reset" && rest.includes("--hard"))
    || (sub === "clean" && rest.some((x) => /^-[a-zA-Z]*f/.test(x) || x === "--force"))
    || (sub === "checkout" && rest.includes("--") && rest.slice(rest.indexOf("--") + 1).some((x) => x === "." || x === ":/"))
    || (sub === "restore" && rest.some((x) => x === "." || x === ":/") && !rest.includes("--staged"));
  if (destroys) {
    const own = (dir + "/").startsWith(`${HOME}/bin/`) || ((dir + "/").startsWith(`${HOME}/GitHub/`) && !(dir + "/").startsWith(`${HOME}/GitHub/.wt-`) && dir !== `${HOME}/GitHub`);
    if (own && env.dirtyOf(dir)) return `it throws away unsaved work in ${dir}, her own checkout; commit or move it first (agents work in their own worktree)`;
  }
  return null;
}

const DESTRUCTIVE_SQL = /\b(DROP\s+(TABLE|INDEX|VIEW|TRIGGER|COLUMN)|DELETE\s+FROM|TRUNCATE)\b|\bALTER\s+TABLE\b[^;]*\bDROP\b/i;

function wranglerProblem(a, cwd) {
  const w = a.findIndex((x) => basename(x) === "wrangler");
  if (w === -1) return null;
  const r = a.slice(w + 1).filter((x) => x !== "--");
  const words = r.filter((x) => !x.startsWith("-"));
  const has = (f) => r.some((x) => x === f || x.startsWith(`${f}=`));
  const dry = has("--dry-run");
  if (!dry && (words[0] === "deploy" || words[0] === "publish" || (words[0] === "pages" && words[1] === "deploy") || (words[0] === "versions" && words[1] === "deploy"))) {
    return "it deploys with a bare wrangler command (stale client, local bindings); ship through the repo's deploy script: `~/bin/land <pr>` or its `npm run deploy…` script";
  }
  if (words[0] === "delete") return "it deletes a Worker";
  if (words[0] === "d1" && (words[1] === "delete" || (words[1] === "time-travel" && words[2] === "restore"))) return `it runs \`wrangler d1 ${words.slice(1, 3).join(" ")}\` on a live database, which cannot be undone`;
  if (["kv", "r2", "queues", "vectorize"].includes(words[0]) && words.includes("delete") && !words.includes("key") && !words.includes("object")) return `it deletes a whole ${words[0]} store`;
  if (words[0] === "d1" && words[1] === "execute" && has("--remote")) {
    const ci = r.findIndex((x) => x === "--command" || x.startsWith("--command="));
    let sql = ci === -1 ? "" : r[ci].includes("=") ? r[ci].slice(r[ci].indexOf("=") + 1) : r[ci + 1] ?? "";
    const fi = r.findIndex((x) => x === "--file" || x.startsWith("--file="));
    if (fi !== -1) {
      const f = r[fi].includes("=") ? r[fi].slice(r[fi].indexOf("=") + 1) : r[fi + 1] ?? "";
      try { sql += "\n" + readFileSync(resolve(cwd, expand(f) ?? f), "utf8"); } catch { return `it runs ${f} on the live database and the guard cannot read the file to check it`; }
    }
    if (DESTRUCTIVE_SQL.test(sql)) return "it drops or deletes rows on a live (--remote) D1 database; builds and migrations never change live records (additive migrations only; a one-record fix is by hand, when she asks)";
  }
  return null;
}

// Her ruling 21 Nov 2026 ("u should have fucking known to do that"): the same check failing twice is a bug
// to root-cause, not a run to repeat. `gh run rerun <id>` is refused when that run failed AND the run of the
// same workflow on the same branch before it also failed. Reads GitHub with gh (5 s cap); unreadable = let through.
function runHistory(id, repo) {
  const R = repo ? ["-R", repo] : [];
  const q = (args) => JSON.parse(execFileSync("gh", args, { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }));
  const run = q(["run", "view", id, ...R, "--json", "workflowName,headBranch,conclusion,databaseId"]);
  const list = q(["run", "list", ...R, "-w", run.workflowName, "-b", run.headBranch, "-L", "6", "--json", "databaseId,conclusion,status"]);
  return { run, list };
}
function rerunProblem(a, env) {
  if (!(a[1] === "run" && a[2] === "rerun")) return null;
  const id = a.slice(3).find((x) => /^\d+$/.test(x));
  const ri = a.indexOf("-R") >= 0 ? a.indexOf("-R") : a.indexOf("--repo");
  if (!id) return null;
  let h; try { h = (env.runHistory ?? runHistory)(id, ri >= 0 ? a[ri + 1] : null); } catch { return null; }
  if (!h || h.run.conclusion !== "failure") return null;
  const before = h.list.filter((r) => r.status === "completed" && r.databaseId !== h.run.databaseId && r.databaseId < h.run.databaseId);
  if (before[0]?.conclusion === "failure") return `the same check (${h.run.workflowName} on ${h.run.headBranch}) has already failed twice in a row; re-running will not change it. Read the failing step, run only that test, fix the cause, push once`;
  return null;
}

/** `gh pr create` with a fix of the last 30 days left unanswered: land's patch check, run when the PR opens. */
function patchCheck(dir, body) {
  const r = spawnSync(resolve(dirname(fileURLToPath(import.meta.url)), "pr-patch-check"), [dir, "-"], { input: body, encoding: "utf8", timeout: 20000 });
  return { code: r.status, msg: (r.stdout || "").trim() };
}
function originSlug(dir) {
  try { return execFileSync("git", ["-C", dir, "remote", "get-url", "origin"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim().replace(/\.git$/, "").replace(/^.*github\.com[:/]/, "").toLowerCase(); } catch { return ""; }
}
function prCreateProblem(a, line, dir, env) {
  if (!dir || !existsSync(dir)) return null; // a folder it cannot see: let through, land asks at merge
  const flag = (names) => { const i = a.findIndex((x) => names.includes(x) || names.some((n) => x.startsWith(`${n}=`))); if (i < 0) return null; return a[i].includes("=") ? a[i].split("=").slice(1).join("=") : a[i + 1]; };
  if (flag(["--fill", "--fill-first", "--web", "-w", "--fill-verbose"]) !== null || a.some((x) => ["--fill", "--fill-first", "--web", "-w", "--fill-verbose"].includes(x))) return null;
  const repo = flag(["--repo", "-R"]);
  if (repo && (env.originSlug ?? originSlug)(dir) !== repo.toLowerCase()) return null; // another repo than the one checked out here: land asks at merge
  let body = String(line);
  const inline = flag(["--body", "-b"]); if (inline) body += "\n" + inline;
  const file = flag(["--body-file", "-F"]);
  if (file && file !== "-") { try { body += "\n" + readFileSync(isAbsolute(file) ? file : resolve(dir, file), "utf8"); } catch { /* unreadable: the line itself may still hold it */ } }
  const r = (env.patchCheck ?? patchCheck)(dir, body);
  return r.code === 1 && r.msg ? `${r.msg}. Add that line to the PR body, then open the PR` : null;
}

/** Why this command line must not run, or null. `env` lets tests stub git. */
export function verdict(line, { cwd = process.cwd(), env = { branchOf, dirtyOf } } = {}) {
  let dir = cwd;
  for (const a of commands(String(line ?? ""))) {
    const cmd = basename(a[0]);
    if (cmd === "cd" && a[1]) { const t = expand(a[1]); dir = t === null || dir === null ? null : isAbsolute(t) ? t : resolve(dir, t); continue; }
    let why = null;
    if (cmd === "rm") {
      const flags = a.slice(1).filter((x) => x.startsWith("-") && x !== "--");
      const recursive = flags.some((x) => x === "--recursive" || /^-[a-zA-Z]*[rR]/.test(x));
      const targets = a.slice(1).filter((x, i, all) => !x.startsWith("-") || all.slice(1, i + 1).includes("--"));
      for (const t of targets) {
        const p = rmTargetProblem(t, cwd);
        if (p && (recursive || /LaunchAgents\/com\.seq\./.test(p))) { why = p; break; }
      }
    } else if (cmd === "git") why = gitProblem(a, cwd, env);
    else if (cmd === "launchctl") {
      if (["unload", "bootout", "remove", "disable"].includes(a[1]) && a.slice(2).some((x) => x.includes("com.seq.") || x.includes("$"))) {
        why = `it stops a com.seq.* scheduled job (launchctl ${a[1]}); jobs are reloaded with ~/bin/install-launchd.sh or the repo's installer, never stopped by hand`;
      }
    } else if (cmd === "gh" && a[1] === "repo" && a[2] === "delete") why = "it deletes a GitHub repository";
    else if (cmd === "gh" && a[1] === "run" && a[2] === "rerun") why = rerunProblem(a, env);
    else if (cmd === "gh" && a[1] === "pr" && a[2] === "create") { why = prCreateProblem(a, line, dir, env); if (why) return `Refused by the PR-open patch check (~/bin/pr-patch-check): ${why}.`; }
    else if (cmd === "security" && /^delete-(generic|internet)-password$/.test(a[1] ?? "")) why = "it deletes a Keychain secret";
    else if (cmd === "diskutil" && /^(erase|zero|secureErase|reformat|partitionDisk)/i.test(a[1] ?? "")) why = "it erases a disk";
    else why = wranglerProblem(a, cwd);
    if (why) return `Blocked by the dangerous-command guard (~/bin/command-guard.mjs): ${why}. If this really must happen, she runs it herself in Terminal.`;
  }
  return null;
}

/** Claude Code and Codex both send { tool_name, tool_input: { command }, cwd }; Codex may send argv. */
export function commandOf(input) {
  const c = input?.tool_input?.command ?? input?.tool_input?.cmd;
  if (Array.isArray(c)) return c.length >= 3 && ["bash", "sh", "zsh"].includes(basename(c[0])) && /^-[a-z]*c/.test(c[1]) ? c.slice(2).join(" ") : c.map((x) => (/[\s'"]/.test(x) ? `'${x.replace(/'/g, "'\\''")}'` : x)).join(" ");
  return typeof c === "string" ? c : null;
}

// ─── --self-test: every rule still refuses, a harmless command still passes ──────────────────────────
const FAILED_TWICE = () => ({ run: { workflowName: "check", headBranch: "feat/x", conclusion: "failure", databaseId: 9 }, list: [{ databaseId: 9, status: "completed", conclusion: "failure" }, { databaseId: 8, status: "completed", conclusion: "failure" }] });
const FAILED_ONCE = () => ({ run: { workflowName: "check", headBranch: "feat/x", conclusion: "failure", databaseId: 9 }, list: [{ databaseId: 9, status: "completed", conclusion: "failure" }, { databaseId: 8, status: "completed", conclusion: "success" }] });
const STUB = { branchOf: () => "main", dirtyOf: () => " M a.txt", runHistory: FAILED_TWICE };
export const MUST_BLOCK = [
  "rm -rf ~/GitHub/boss-os", "rm -fr /Users/x/Brains", "rm -r -f ~", "cd /tmp && rm -rf $HOME/bin", "rm -rf \"$TARGET\"", "rm --recursive --force ~/Work",
  "rm -rf /", "rm -rf /tmp", "bash -lc 'rm -rf ~/.boss-os'", "rm ~/Library/LaunchAgents/com.seq.ci-sweep.plist", "sudo rm -rf /usr/local",
  "git push --force origin main", "git push -f", "git push origin +main", "git push --force-with-lease origin HEAD:main", "git push origin :main", "git push origin --delete master",
  "git reset --hard origin/main", "git clean -fdx", "git checkout -- .",
  "wrangler deploy", "npx wrangler deploy --env production", "npx wrangler pages deploy dist", "wrangler versions deploy",
  "npx wrangler d1 execute WP_OS_DB --remote --command \"DELETE FROM prospects\"", "wrangler d1 execute db --remote --command='DROP TABLE x'", "wrangler d1 delete boss-os", "wrangler d1 time-travel restore db --timestamp=1",
  "wrangler r2 bucket delete media", "wrangler delete --name boss-os",
  "launchctl unload ~/Library/LaunchAgents/com.seq.ci-sweep.plist", "launchctl disable gui/501/$j", "gh run rerun 123 -R seq23/x", "launchctl bootout gui/501/com.seq.housekeeping",
  "gh repo delete seq23/x --yes", "security delete-generic-password -s west-peek-os-vault", "diskutil eraseDisk APFS X disk2",
];
export const MUST_PASS = [
  "ls -la", "rm -rf /tmp/claude-501/scratch/x", "rm -rf node_modules", "rm -rf ./dist", "rm -rf ~/GitHub/.wt-phase1-boss", "rm notes.txt", "rm -rf /private/var/folders/ab/T/x",
  "git push -u origin phase1-drill-guard", "git push --force origin my-branch", "git status", "git reset --soft HEAD~1", "git clean -n",
  "wrangler deploy --dry-run", "npm run deploy:production", "~/bin/land 12", "npx wrangler d1 execute WP_OS_DB --local --command \"DELETE FROM x\"",
  "npx wrangler d1 execute WP_OS_DB --remote --command \"SELECT COUNT(*) FROM standing_duties\"", "npx wrangler d1 export WP_OS_DB --env production --remote --output /tmp/x.sql",
  "launchctl list | grep com.seq.", "gh run rerun 456", "launchctl enable gui/501/$j", "launchctl kickstart gui/501/com.seq.housekeeping", "echo 'rm -rf ~' > notes.txt", "grep -n \"git push --force\" README.md",
];
export function selfTest() {
  const cwd = `${HOME}/GitHub/boss-os`;
  const missed = MUST_BLOCK.filter((c) => !verdict(c, { cwd, env: STUB }));
  const wrong = MUST_PASS.filter((c) => verdict(c, { cwd: `${HOME}/GitHub/.wt-phase1-bin`, env: { branchOf: () => "phase1-drill-guard", dirtyOf: () => "", runHistory: FAILED_ONCE } }));
  return { missed, wrong };
}

async function main() {
  if (process.argv.includes("--self-test")) {
    const { missed, wrong } = selfTest();
    if (missed.length || wrong.length) {
      if (missed.length) console.error(`NAMED STOP [GUARD_BLIND] not refused: ${missed.join(" | ")}`);
      if (wrong.length) console.error(`NAMED STOP [GUARD_TOO_WIDE] refused a harmless command: ${wrong.join(" | ")}`);
      process.exit(1);
    }
    console.log(`SELF-TEST OK — ${MUST_BLOCK.length} dangerous commands refused, ${MUST_PASS.length} harmless ones let through`);
    return;
  }
  let input;
  try { input = JSON.parse(readFileSync(0, "utf8")); } catch (e) { console.error(`command-guard: unreadable hook input (${e.message}); let through`); return; }
  const line = commandOf(input);
  if (!line) return;
  let why = null;
  try { why = verdict(line, { cwd: input.cwd || process.cwd() }); } catch (e) { console.error(`command-guard: could not judge the command (${e.message}); let through`); return; }
  if (!why) return;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: why } }));
}

if (import.meta.url === `file://${process.argv[1]}`) main();
