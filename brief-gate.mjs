// Agent launch gate (her rulings 21-22 Nov 2026; weekend post-mortem 22 Nov: 59% of Fri-Sun spend was general-purpose
// agents, which skipped this gate and the builder/reviewer 200K compaction cap and ran to 417K context).
//  1. Work agents must be `builder` or `reviewer` (both carry autoCompactWindow 200K). Read-only helpers pass.
//  2. A builder brief must carry the reviewer-POV sections (agent-brief skill) and its REVIEW CLASS line
//     (`REVIEW CLASS: none — <why>` or money|children|private-data|store|delete|launch — <why>), which the builder copies
//     into the PR body as `Review class: ...`: land refuses a PR without it (eng check of #155, 23 Nov 2026).
//  3. A review of a PR whose task sheet says FAIL is a re-check: the brief must carry "RECHECK OF:" (the failed items
//     only, her ruling 21 Nov 2026), never a fresh full review (42% of the weekend went on reviews and redos).
// No limit on how many agents run (her words 22 Nov 2026: "i dont want to cap the agents. i just want to make them work efficiently").
import { readdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
  let j;try{j=JSON.parse(s)}catch{process.exit(0)}
  if(j.tool_name!=='Agent')process.exit(0);
  const i=j.tool_input||{};const t=i.subagent_type||'general-purpose';
  const READ_ONLY=['Explore','Plan','web-fetch','claude-code-guide','statusline-setup','fork'];
  if(READ_ONLY.includes(t))process.exit(0);
  if(t!=='builder'&&t!=='reviewer'){
    console.error(`AGENT_TYPE_REFUSED: "${t}" has no 200K compaction cap and skips the brief gate. Use subagent_type "builder" (build/fix/land) or "reviewer" (any review).`);
    process.exit(2);
  }
  const p=(i.prompt||'').toUpperCase();
  if(t==='builder'){
    const need=['THE REVIEW YOU WILL FACE','HOW IT BREAKS','SELF-PROOF','HER WORDS'].filter(k=>!p.includes(k));
    if(!/REVIEW CLASS:\s*(NONE|MONEY|CHILDREN|PRIVATE-DATA|STORE|DELETE|LAUNCH)\s*(—|–|--|-|:)\s*\S/.test(p))need.push('REVIEW CLASS: none|money|children|private-data|store|delete|launch — <why> (the builder copies it into the PR body as Review class: ...; land refuses a PR without it)');
    if(need.length){console.error('BRIEF_INCOMPLETE: builder brief is missing: '+need.join(', ')+'. Write it from the agent-brief skill (reviewer checks first, promise audit, same value everywhere, outage test per external read).');process.exit(2);}
  }
  if(t==='reviewer'&&!p.includes('RECHECK OF:')){
    const prs=new Set([...(i.prompt||'').matchAll(/([\w.-]+\/[\w.-]+)#(\d+)/g)].map(m=>(m[1]+'#'+m[2]).toLowerCase()));
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
