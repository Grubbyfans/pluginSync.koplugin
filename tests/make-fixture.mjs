import { zip } from '../server/src/zip.js';
import fs from 'node:fs';
fs.mkdirSync('.research',{recursive:true});
fs.writeFileSync('.research/node-fixture.zip',zip([
  {name:'demo.koplugin/main.lua',data:Buffer.from('return {}')},
  {name:'demo.koplugin/_meta.lua',data:Buffer.from('return {}')},
  {name:'demo.koplugin/中文.txt',data:Buffer.from('你好')},
]));
