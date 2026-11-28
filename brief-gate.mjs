// Agent launch gate (her rulings 21-22 Nov 2026; weekend post-mortem 22 Nov: 59% of Fri-Sun spend was general-purpose
// agents, which skipped this gate and the builder/reviewer 200K compaction cap and ran to 417K context).
//  1. Work agents must be `builder`, `reviewer`, `helper`, `claude` or `general-purpose` (all carry autoCompactWindow 200K in ~/.claude/agents since 25 Nov 2026; helper added that day for any one-off job). Read-only helpers pass.
//  2. A builder brief must carry the reviewer-POV sections (agent-brief skill) and its REVIEW CLASS line
//     (`REVIEW CLASS: none — <why>` or one of land's classes — <why>; the words are land's ONE list, REVIEW_CLASSES, read
//     from the land beside this file: money|private-data|delete|store|launch|outreach since her final list of 27 Nov
//     2026), which the builder copies into the PR body as `Review class: ...` (pr-body-template.md carries the form).
//  3. A review of a PR whose task sheet says FAIL is a re-check: the brief must carry "RECHECK OF:" (the failed items
//     only, her ruling 21 Nov 2026), never a fresh full review (42% of the weekend went on reviews and redos).
//  4. CLAIMS PROVEN (her order 24 Nov 2026, "do this now", after both builder fails that day were PR-body claims nobody
//     had run: "writes are refused" when they ran, "runner on @main" with the old pin still in the file): a reviewer is
//     not launched on a PR whose `## Self-review` has an unproven line. Every bullet or table row there must carry the
//     command that proves it in backticks and what it printed after a `→` (or `->`), or be `n/a — <why, 4+ words>`.
//     Structure only: whether the proof is honest is the reviewer's call (it re-runs the commands). A PR body that
//     cannot be read refuses the launch (Rule 0: never a pass on nothing read).
// No limit on how many agents run (her words 22 Nov 2026: "i dont want to cap the agents. i just want to make them work efficiently").
import { readdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
// The PR body: from BRIEF_GATE_PR_BODIES/<owner>_<repo>_<n>.md in tests, else `gh pr view`; null when unreadable.
const prBody=(ref)=>{const[r,n]=ref.split('#');const d=process.env.BRIEF_GATE_PR_BODIES;
  try{if(d)return readFileSync(join(d,r.replace('/','_')+'_'+n+'.md'),'utf8');
    return execFileSync('gh',['pr','view',n,'--repo',r,'--json','body','-q','.body'],{encoding:'utf8',timeout:7000,stdio:['ignore','pipe','ignore']});}
  catch{return null}};
// Each line of `## Self-review` that is not proven -> [lines]; null when the section is missing or holds no rows.
export const unproven=(body)=>{const L=String(body).split('\n');const i=L.findIndex(l=>/^#{1,4}\s*self-review\b/i.test(l.trim()));
  if(i<0)return null;const bad=[];let rows=0,table=false;
  for(const raw of L.slice(i+1)){const l=raw.trim();if(/^#{1,4}\s/.test(l))break;
    if(/^\|/.test(l)){if(/^\|[\s|:-]+\|?$/.test(l))continue;if(!table){table=true;continue}}else table=false; // a table's first row is its header
    if(!/^(\||[-*+]\s|\d+[.)]\s)/.test(l))continue;rows++;
    const na=/\bn\/a\b\s*(—|–|--|-|:)\s*(\S+\s+){3}\S/i.test(l);
    const proof=/`[^`]{3,}`[^`]*?(→|->)\s*\S/.test(l);
    if(!na&&!proof)bad.push(l.slice(0,90));}
  return rows?bad:null};
let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
  let j;try{j=JSON.parse(s)}catch{process.exit(0)}
  if(j.tool_name!=='Agent')process.exit(0);
  const i=j.tool_input||{};const t=i.subagent_type||'general-purpose';
  const READ_ONLY=['helper','claude','general-purpose','Explore','Plan','web-fetch','claude-code-guide','statusline-setup','fork'];
  if(READ_ONLY.includes(t))process.exit(0);
  if(t!=='builder'&&t!=='reviewer'){
    console.error(`AGENT_TYPE_REFUSED: "${t}" has no 200K compaction cap and skips the brief gate. Use "helper" (any other job, same tools, 200K cap), "builder" (code build/fix/land) or "reviewer" (any review).`);
    process.exit(2);
  }
  const p=(i.prompt||'').toUpperCase();
  if(t==='builder'){
    const need=['THE REVIEW YOU WILL FACE','HOW IT BREAKS','SELF-PROOF','HER WORDS'].filter(k=>!p.includes(k));
    // The class words are land's ONE list (REVIEW_CLASSES in the land beside this file). Unreadable: any one word passes,
    // since the line itself is what the builder needs, and land still reads an unknown word as a class.
    let classes=null;
    try{const m=readFileSync(new URL('./land',import.meta.url),'utf8').match(/^REVIEW_CLASSES="([a-z|-]+)"$/m);if(m)classes=m[1].toUpperCase().split('|');}catch{}
    const cls=(p.match(/REVIEW CLASS:\s*([A-Z-]+)\s*(?:—|–|--|-|:)\s*\S/)||[])[1];
    if(!cls||(cls!=='NONE'&&classes&&!classes.includes(cls)))need.push(`REVIEW CLASS: none|${(classes||['<class>']).join('|').toLowerCase()} — <why> (the builder copies it into the PR body as Review class: ...; pr-body-template.md carries the form)`);
    // 4. Built from HER words, not mine (her words 24 Nov 2026: "I TOLD U THE FUCKING BRIEFS WERE WRONG TO BEGIN WITH IVE
    //    COMPLAINED ABOUT BRIEFS COUNTLESS TIMES"; Noelle was built wrong twice, and extras nobody asked for burned her week).
    if(!/ASKED FOR:\s*["“][^"”]{8,}["”]/.test(p))need.push('ASKED FOR: "<her own words, verbatim, in quotes>" (what she asked for, never my summary)');
    if(!/NOT ASKED FOR:\s*\S/.test(p))need.push('NOT ASKED FOR: <every item I added on my own, or "none">');
    if(!/HER YES:\s*["“][^"”]{1,}["”]/.test(p))need.push('HER YES: "<her reply, verbatim>" to the 5-line "what this builds" preview I sent her in chat before launch');
    if(need.length){console.error('BRIEF_INCOMPLETE: builder brief is missing: '+need.join(', ')+'. Write it from the agent-brief skill (reviewer checks first, promise audit, same value everywhere, outage test per external read).');process.exit(2);}
  }
  const prs=new Set([...(i.prompt||'').matchAll(/([\w.-]+\/[\w.-]+)#(\d+)/g)].map(m=>(m[1]+'#'+m[2]).toLowerCase()));
  if(t==='reviewer'){
    const out=[];
    for(const ref of prs){const b=prBody(ref);
      if(b===null){out.push(`${ref}: its PR body could not be read (retry; never a review on nothing read)`);continue}
      const u=unproven(b);
      if(u===null)out.push(`${ref}: no \`## Self-review\` section with rows`);
      else if(u.length)out.push(`${ref}: ${u.length} unproven line(s), first: "${u[0]}"`);}
    if(out.length){console.error(`CLAIMS_UNPROVEN: ${out.join('; ')}. Each line under ## Self-review must carry the command run, in backticks, and what it printed after → (e.g. - runner pinned to main: \`grep -n runner_ref .github/workflows/*.yml\` → no match), or be "n/a — <why, 4+ words>". Send the PR back to its builder to prove or delete each claim (builder.md check 5, her order 24 Nov 2026); never review it as is.`);process.exit(2);}
  }
  if(t==='reviewer'&&!p.includes('RECHECK OF:')){
    let failed=[];
    try{
      const dir=process.env.TASK_SHEETS_DIR||join(homedir(),'Work','tasks');
      for(const f of readdirSync(dir)){
        if(!f.endsWith('.md'))continue;
        const m=readFileSync(join(dir,f),'utf8').split('\n')[0].match(/^STATUS:\s*FAIL\s+(\S+#\d+)/i);
        if(m&&prs.has(m[1].toLowerCase()))failed.push(m[1]+' ('+f+')');
      }
    }catch{}
    if(failed.length){
      console.error(`RECHECK_ONLY: ${failed.join(', ')} already failed review. A re-check covers only the failed items and the diff since, in 15 minutes or less (her ruling 21 Nov 2026). Put "RECHECK OF: <the failed items>" in the brief. A fresh full review is right only when new code went in beyond the fixes: then say so in the RECHECK OF: line.`);
      process.exit(2);
    }
  }
  process.exit(0);
});
