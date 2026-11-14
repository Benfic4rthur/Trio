import path from 'node:path';
import { mkdir } from 'node:fs/promises';
import { BASE_URL, createSafePage, viewports, contactSheet, saveJSON } from './browser.mjs';
const run=path.resolve('site/qa/artifacts',`opening-${new Date().toISOString().replace(/[:.]/g,'-')}`); await mkdir(run,{recursive:true});
const shots=[];
for(const [name,viewport] of [['desktop',viewports.desktop],['phone',viewports.phone]]) {
 const session=await createSafePage({viewport,touch:name==='phone'});
 try { await session.page.goto(BASE_URL,{waitUntil:'networkidle'}); const file=path.join(run,`${name}-hero.png`); await session.page.screenshot({path:file}); shots.push({file,label:`${name} opening`}); console.log(file); }
 finally { await session.close(); }
}
await contactSheet(shots,path.join(run,'opening-sheet.png'),{columns:2,width:1440});
await saveJSON('site/qa/artifacts/latest-opening.json',{run,shots,sheet:path.join(run,'opening-sheet.png')}); console.log(path.join(run,'opening-sheet.png'));
