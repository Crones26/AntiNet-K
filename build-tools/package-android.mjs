import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {entries,inflate,zip,crc32,poolStrings,rebuildPool} from './apk-format.mjs';

const root=path.resolve(import.meta.dirname,'..').replaceAll('\\','/');
const phase=process.argv[2]||'release';
if(!['baseline','trial','lab','release'].includes(phase))throw new Error('Unknown phase');
const buildPath=phase==='lab'?`${root}/build/android-lab`:`${root}/build/android-local`;
const source=fs.readFileSync(`${root}/build/carrier/official-1.2.25.2802.apk`);
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
if(hash(source)!=='670595d787be699f960dd71e1a3eab55cdf1d4d17522851d793e49f1c6d09158')throw new Error('Official carrier differs');
const outDir=`${root}/build/apk`;fs.mkdirSync(outDir,{recursive:true});
const isQa=phase!=='release';
const packageName=isQa?'org.antinetmod.karing.test':'org.antinetmod.karing';
const abis=['baseline','lab'].includes(phase)?['arm64-v8a']:['armeabi-v7a','arm64-v8a'];
const sourceBuild=JSON.parse(fs.readFileSync(`${buildPath}/source-build.json`,'utf8').replace(/^\uFEFF/,''));
if(['trial','release'].includes(phase)&&sourceBuild.entry!=='lib/main.dart')throw new Error('Production APK must use the normal application entry point');
const actualSourceHash=execFileSync(process.execPath,[`${root}/build-tools/source-hash.mjs`,sourceBuild.entry],{encoding:'utf8'}).trim();
if(sourceBuild.sourceSha256!==actualSourceHash)throw new Error('AOT does not match current sources; assemble before packaging');
const fresh=(name,data,method=8)=>({name,method,crc:crc32(data),size:data.length,data:method===8?zlib.deflateRawSync(data):data});
function manifest(bytes){
 const head=Buffer.from(bytes.subarray(0,bytes.readUInt16LE(2))),chunks=[];
 let strings,poolIndex,mapIndex;
 for(let at=head.length;at<bytes.length;){const c=Buffer.from(bytes.subarray(at,at+bytes.readUInt32LE(at+4)));if(c.readUInt16LE(0)===1){poolIndex=chunks.length;strings=poolStrings(c);}if(c.readUInt16LE(0)===0x180)mapIndex=chunks.length;chunks.push(c);at+=c.length;}
 const index=v=>{let i=strings.indexOf(v);if(i<0)i=strings.push(v)-1;return i;};
 const attributes=c=>Array.from({length:c.readUInt16LE(28)},(_,i)=>16+c.readUInt16LE(24)+i*c.readUInt16LE(26));
 const put=(c,a,value)=>{const i=index(value);c.writeUInt32LE(i,a+8);c.writeUInt8(3,a+15);c.writeUInt32LE(i,a+16);};
 for(let i=0;i<chunks.length;i++){
  let c=chunks[i];if(c.readUInt16LE(0)!==0x102)continue;
  const tag=strings[c.readUInt32LE(20)];
  for(const a of attributes(c)){
   const name=strings[c.readUInt32LE(a+4)],raw=c.readUInt32LE(a+8),value=raw===0xffffffff?null:strings[raw];
   if(tag==='manifest'&&name==='package')put(c,a,packageName);
   if(tag==='manifest'&&name==='versionCode')c.writeUInt32LE(2804,a+16);
   if(tag==='manifest'&&name==='versionName')put(c,a,'1.2.25');
   if(tag==='application'&&name==='label')put(c,a,isQa?'AntiNet K Test':'AntiNet K');
   if(name==='authorities'&&value?.startsWith('com.nebula.karing'))put(c,a,value.replace('com.nebula.karing',packageName));
   if((tag==='uses-permission'||tag==='permission')&&name==='name'&&value?.startsWith('com.nebula.karing.'))put(c,a,value.replace('com.nebula.karing',packageName));
  }
  if(tag==='application'){
   let attr=attributes(c).find(a=>strings[c.readUInt32LE(a+4)]==='debuggable');
   if(attr===undefined&&isQa){
    const attrIndex=index('debuggable'),oldMap=chunks[mapIndex],required=8+(attrIndex+1)*4;
    if(oldMap.length<required){const m=Buffer.alloc(required);oldMap.copy(m);m.writeUInt32LE(required,4);chunks[mapIndex]=m;}
    chunks[mapIndex].writeUInt32LE(0x0101000f,8+attrIndex*4);
    const attrs=attributes(c).map(a=>Buffer.from(c.subarray(a,a+20)));
    const added=Buffer.alloc(20);added.writeUInt32LE(index('http://schemas.android.com/apk/res/android'),0);added.writeUInt32LE(attrIndex,4);added.writeUInt32LE(0xffffffff,8);added.writeUInt16LE(8,12);added.writeUInt8(0x12,15);added.writeUInt32LE(0xffffffff,16);attrs.push(added);
    const resourceId=a=>{const n=a.readUInt32LE(4),m=chunks[mapIndex];return 8+n*4<m.length?m.readUInt32LE(8+n*4):0;};
    attrs.sort((a,b)=>resourceId(a)-resourceId(b));
    const prefix=c.subarray(0,16+c.readUInt16LE(24));c=Buffer.concat([prefix,...attrs]);c.writeUInt32LE(c.length,4);c.writeUInt16LE(attrs.length,28);chunks[i]=c;
   }else if(attr!==undefined){c.writeUInt32LE(0xffffffff,attr+8);c.writeUInt8(0x12,attr+15);c.writeUInt32LE(isQa?0xffffffff:0,attr+16);}
  }
 }
 chunks[poolIndex]=rebuildPool(chunks[poolIndex],strings);
 const result=Buffer.concat([head,...chunks]);result.writeUInt32LE(result.length,4);return result;
}
const original=entries(source),result=[],changes=[];
for(const entry of original){
 if(/^META-INF\/(?:MANIFEST\.MF|[^/]+\.(?:SF|RSA|DSA|EC))$/i.test(entry.name))continue;
 if(entry.name.startsWith('assets/flutter_assets/'))continue;
 if(entry.name.startsWith('lib/')&&!abis.some(abi=>entry.name.startsWith(`lib/${abi}/`)))continue;
 if(abis.some(abi=>entry.name===`lib/${abi}/libapp.so`)){
  const abi=entry.name.split('/')[1];result.push(fresh(entry.name,fs.readFileSync(`${buildPath}/${abi}/app.so`)));changes.push(entry.name);
 }
 else if(entry.name==='AndroidManifest.xml'){result.push(fresh(entry.name,manifest(inflate(entry))));changes.push(entry.name);}
 else result.push(entry);
}
function addAssets(dir,relative=''){
 for(const item of fs.readdirSync(dir,{withFileTypes:true})){const rel=relative?relative+'/'+item.name:item.name,p=path.join(dir,item.name);if(item.isDirectory())addAssets(p,rel);else result.push(fresh('assets/flutter_assets/'+rel,fs.readFileSync(p)));}
}
addAssets(`${buildPath}/flutter_assets`);
const retainedNative=original.filter(e=>e.name.endsWith('.dex')||(abis.some(abi=>e.name.startsWith(`lib/${abi}/`))&&!e.name.endsWith('/libapp.so')));
for(const entry of retainedNative){const actual=result.find(e=>e.name===entry.name);if(!actual||hash(inflate(actual))!==hash(inflate(entry)))throw new Error('Native payload changed: '+entry.name);}
const output=zip(result);fs.writeFileSync(`${outDir}/${phase}-unsigned.apk`,output);
fs.writeFileSync(`${outDir}/${phase}-payload.json`,JSON.stringify({phase,packageName,sourceBuild,carrierSha256:hash(source),outputSha256:hash(output),abi:abis,nativeStrategy:'All official DEX and selected-ABI native libraries retained exactly except the rebuilt Dart libapp.so.',unchangedNative:retainedNative.map(e=>({name:e.name,sha256:hash(inflate(e))})),changes,flutterAssets:result.filter(e=>e.name.startsWith('assets/flutter_assets/')).length,bytes:output.length},null,2)+'\n');
console.log(JSON.stringify({phase,bytes:output.length,unchangedNative:retainedNative.length,output:`${outDir}/${phase}-unsigned.apk`}));
