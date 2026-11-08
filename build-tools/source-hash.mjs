import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const root=path.resolve(import.meta.dirname,'..');
const entry=process.argv[2]||'lib/main.dart';
const paths=new Set(['pubspec.yaml','pubspec.lock',entry]);
function walk(dir){for(const item of fs.readdirSync(path.join(root,dir),{withFileTypes:true})){
 const p=dir+'/'+item.name;
 if(item.isDirectory())walk(p);else if(p.endsWith('.dart'))paths.add(p);
}}
walk('lib');walk('third_party/vpn_service/lib');
const digest=crypto.createHash('sha256');
for(const p of [...paths].sort()){digest.update(p+'\0');digest.update(fs.readFileSync(path.join(root,p)));digest.update('\0');}
console.log(digest.digest('hex'));
