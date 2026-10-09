import fs from 'node:fs';
import {Connection,pages} from './runtime.mjs';
export async function connect(port=9236) {
 const list=await pages(port);
 const t=list.find(t=>t.url==='app://-/index.html')||list.find(t=>/^app:\/\/-\/index\.html/.test(t.url));
 if(!t)throw Error('No Codex shell target');
 const c=new Connection(t.webSocketDebuggerUrl);
 await c.ready;
 return {call:(...args)=>c.call(...args),evaluate:(...args)=>c.eval(...args),
         close:()=>c.close(),target:t,listeners:c.listeners};
}
if(process.argv[1]?.endsWith('/cdp.mjs')) {
 const c=await connect(Number(process.env.THEME_PORT||9236));
 try{
  const mode=process.argv[2];
  if(mode==='eval')console.log(JSON.stringify(await c.evaluate(fs.readFileSync(process.argv[3],'utf8')),null,2));
  else if(mode==='shot'){const r=await c.call('Page.captureScreenshot',{format:'png'});fs.writeFileSync(process.argv[3],Buffer.from(r.data,'base64'))}
 }finally{c.close()}
}
