import fs from 'node:fs/promises';
import path from 'node:path';
import { ROOT } from './file-rules.js';

let lastRun=0;
export async function cleanupUnlinkedFiles(client) {
  if(Date.now()-lastRun<3600000)return;
  lastRun=Date.now();
  // Originals referenced by any historical version remain protected, including detached files.
  const retained=new Set((await client.query('SELECT storage_key FROM legal.files')).rows.map(f=>f.storage_key));
  for(const job of (await client.query("SELECT id FROM legal.jobs WHERE status IN ('pending','running')")).rows) retained.add(job.id);
  let names;
  try {names=await fs.readdir(ROOT);} catch(error){if(error.code==='ENOENT')return;throw error;}
  for(const name of names) {
    if(!/^[a-f0-9-]+(?:\.tmp)?$/i.test(name)||retained.has(name))continue;
    const target=path.resolve(ROOT,name),base=path.resolve(ROOT)+path.sep;
    if(!target.startsWith(base))continue;
    const stat=await fs.lstat(target);
    if(stat.isFile()&&!stat.isSymbolicLink()&&Date.now()-stat.mtimeMs>86400000) await fs.unlink(target);
  }
}
