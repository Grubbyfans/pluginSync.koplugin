import fs from 'node:fs/promises';
import { zip } from '../server/src/zip.js';
const metadata=JSON.parse(await fs.readFile('pluginsync.json','utf8'));
const luaMetadata=await fs.readFile('_meta.lua','utf8');
if (luaMetadata.match(/\bversion\s*=\s*"([^"]+)"/)?.[1] !== metadata.version)
  throw new Error('_meta.lua and pluginsync.json versions must match');
const names=['_meta.lua','main.lua','api.lua','version.lua','fsutil.lua','archive.lua','installer.lua','catalog.lua','diagnostics.lua','history.lua','discovery.lua','lanhttp.lua','pluginsync.json','README.md'];
const files=[];
for (const name of names) files.push({name:`pluginsync.koplugin/${name}`,data:await fs.readFile(name)});
await fs.mkdir('dist',{recursive:true});
await fs.writeFile('dist/pluginsync.koplugin.zip',zip(files));
console.log('Created dist/pluginsync.koplugin.zip');
