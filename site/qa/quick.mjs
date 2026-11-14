import path from 'node:path';
import { mkdir } from 'node:fs/promises';
import { BASE_URL, createSafePage, viewports, contactSheet, auditPage, saveJSON } from './browser.mjs';
const run = path.resolve('site/qa/artifacts', `quick-${new Date().toISOString().replace(/[:.]/g,'-')}`);
await mkdir(run,{recursive:true});
const results = [];
for (const [name,options] of Object.entries({desktop:{viewport:viewports.desktop},phone:{viewport:viewports.phone,touch:true},compact:{viewport:viewports.compact,touch:true},reduced:{viewport:viewports.desktop,reducedMotion:true}})) {
  const session = await createSafePage(options);
  try {
    await session.page.goto(BASE_URL,{waitUntil:'networkidle'});
    const shots=[];
    async function shot(label) { const file=path.join(run,`${name}-${label}.png`); await session.page.screenshot({path:file}); shots.push({file,label:`${name} · ${label}`}); }
    await shot('hero');
    if(name!=='compact') {
      for(const id of ['wave','experience','installation','download']) {
        const y=await session.page.locator('section#'+id).evaluate(element=>element.getBoundingClientRect().top+scrollY);
        await session.page.evaluate(y=>scrollTo({top:y,behavior:'instant'}),y+(id==='wave'?180:0));
        await session.page.waitForTimeout(220);
        await shot(id);
      }
    }
    const audit=await auditPage(session.page);
    results.push({name,audit,activity:session.activity,shots});
    await saveJSON(path.join(run,`${name}.json`),results.at(-1));
    console.log(JSON.stringify({name,hero:shots[0].file,overflow:audit.scroll.horizontalOverflow,errors:session.activity.errors,http:session.activity.httpErrors}));
  } finally { await session.close(); }
}
await contactSheet(results.find(x=>x.name==='desktop').shots,path.join(run,'desktop-sheet.png'));
await contactSheet(results.find(x=>x.name==='phone').shots.slice(0,3),path.join(run,'phone-sheet.png'),{columns:3,width:1170});
await saveJSON(path.resolve('site/qa/artifacts/latest-quick.json'),{run,results});
console.log(JSON.stringify({run,desktopSheet:path.join(run,'desktop-sheet.png'),phoneSheet:path.join(run,'phone-sheet.png')}));
