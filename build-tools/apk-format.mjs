import fs from 'node:fs/promises';
import zlib from 'node:zlib';
import crypto from 'node:crypto';

export function entries(bytes) {
  let eocd = bytes.length - 22;
  while (eocd >= Math.max(0, bytes.length - 65558) && bytes.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd < 0) throw new Error('ZIP directory missing');
  const result = []; let p = bytes.readUInt32LE(eocd + 16);
  for (let i = 0; i < bytes.readUInt16LE(eocd + 10); i++) {
    const nl = bytes.readUInt16LE(p + 28), el = bytes.readUInt16LE(p + 30), cl = bytes.readUInt16LE(p + 32);
    const offset = bytes.readUInt32LE(p + 42), size = bytes.readUInt32LE(p + 20);
    const dataOffset = offset + 30 + bytes.readUInt16LE(offset + 26) + bytes.readUInt16LE(offset + 28);
    result.push({name: bytes.toString('utf8', p + 46, p + 46 + nl), method: bytes.readUInt16LE(p + 10),
      crc: bytes.readUInt32LE(p + 16), size: bytes.readUInt32LE(p + 24), data: bytes.subarray(dataOffset, dataOffset + size)});
    p += 46 + nl + el + cl;
  }
  return result;
}
export function inflate(entry) { return entry.method === 8 ? zlib.inflateRawSync(entry.data) : entry.data; }
const crcTable = Array.from({length:256}, (_, n) => { for(let i=0;i<8;i++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1; return n >>> 0; });
export function crc32(data) { let crc = 0xffffffff; for(const n of data) crc = crcTable[(crc ^ n) & 255] ^ (crc >>> 8); return (crc ^ 0xffffffff) >>> 0; }
function fresh(name, data, method=8) { return {name, method, crc:crc32(data), size:data.length, data:method===8?zlib.deflateRawSync(data):data}; }
export function zip(list) {
  const locals = [], central = []; let offset = 0;
  for (const e of list) {
    const name = Buffer.from(e.name, 'utf8'), h = Buffer.alloc(30), c = Buffer.alloc(46);
    h.writeUInt32LE(0x04034b50); h.writeUInt16LE(20,4); h.writeUInt16LE(0x800,6); h.writeUInt16LE(e.method,8);
    h.writeUInt32LE(e.crc,14); h.writeUInt32LE(e.data.length,18); h.writeUInt32LE(e.size,22); h.writeUInt16LE(name.length,26);
    c.writeUInt32LE(0x02014b50); c.writeUInt16LE(20,4); c.writeUInt16LE(20,6); c.writeUInt16LE(0x800,8); c.writeUInt16LE(e.method,10);
    c.writeUInt32LE(e.crc,16); c.writeUInt32LE(e.data.length,20); c.writeUInt32LE(e.size,24); c.writeUInt16LE(name.length,28); c.writeUInt32LE(offset,42);
    locals.push(h,name,e.data); central.push(c,name); offset += h.length+name.length+e.data.length;
  }
  const directory=Buffer.concat(central), end=Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(list.length,8); end.writeUInt16LE(list.length,10); end.writeUInt32LE(directory.length,12); end.writeUInt32LE(offset,16);
  return Buffer.concat([...locals,directory,end]);
}
// Old aapt pools can contain CESU-8 surrogate pairs alongside standard UTF-8.
// Buffer.toString('utf8') replaces each surrogate byte with U+FFFD.
function poolUtf8(b, start, end) {
  let value='';
  for(let p=start;p<end;) {
    const lead=b[p++]; let code, extra, minimum;
    if(lead<128){value+=String.fromCharCode(lead);continue;}
    if(lead>=0xc0&&lead<=0xdf){code=lead&31;extra=1;minimum=128;}
    else if(lead>=0xe0&&lead<=0xef){code=lead&15;extra=2;minimum=2048;}
    else if(lead>=0xf0&&lead<=0xf4){code=lead&7;extra=3;minimum=65536;}
    else throw new Error('Invalid resource UTF-8 lead byte');
    if(p+extra>end)throw new Error('Truncated resource UTF-8');
    for(let i=0;i<extra;i++){const next=b[p++];if((next&0xc0)!==0x80)throw new Error('Invalid resource UTF-8 continuation');code=(code<<6)|(next&63);}
    // Modified UTF-8 encodes embedded NUL as C0 80; permit UTF-16 surrogates.
    if((code<minimum&&!(lead===0xc0&&code===0))||code>0x10ffff)throw new Error('Invalid resource UTF-8 code point');
    value+=String.fromCodePoint(code);
  }
  return value;
}
function poolEntries(b) {
  const values=[], header=b.readUInt16LE(2), count=b.readUInt32LE(8), flags=b.readUInt32LE(16), start=b.readUInt32LE(20);
  for(let i=0;i<count;i++) {
    let p=start+b.readUInt32LE(header+i*4);const begin=p;let value;
    if(flags&256) {
      let chars=b[p++];if(chars&128)chars=((chars&127)<<8)|b[p++];
      let n=b[p++]; if(n&128)n=((n&127)<<8)|b[p++];
      value=poolUtf8(b,p,p+n);
      if(value.length!==chars||b[p+n]!==0)throw new Error('Invalid resource string length/terminator');
      p+=n+1;
    } else {
      let n=b.readUInt16LE(p); p+=2;
      if(n&32768) { n=((n&32767)<<16)|b.readUInt16LE(p); p+=2; }
      value=b.toString('utf16le',p,p+n*2);p+=n*2+2;
    }
    values.push({value,raw:b.subarray(begin,p)});
  }
  return values;
}
export function poolStrings(b) { return poolEntries(b).map(entry=>entry.value); }
export function rebuildPool(original, values) {
  const headerLen=original.readUInt16LE(2), styleCount=original.readUInt32LE(12), flags=original.readUInt32LE(16);
  const header=Buffer.from(original.subarray(0,headerLen));
  const originalCount=original.readUInt32LE(8);
  const originalEntries=poolEntries(original);
  const offsets=Buffer.alloc(values.length*4), styleOffsets=original.subarray(headerLen+originalCount*4,headerLen+(originalCount+styleCount)*4);
  header.writeUInt32LE(values.length,8);
  let length=0; const pieces=[];
  const shortLen=n=>n<128?Buffer.from([n]):Buffer.from([(n>>>8)|128,n&255]);
  for(let i=0;i<values.length;i++) {
    offsets.writeUInt32LE(length,i*4); const value=values[i]; let encoded;
    // Keep every unchanged entry byte-for-byte, including its original encoding.
    if(originalEntries[i]?.value===value)encoded=originalEntries[i].raw;
    else if(flags&256) { const utf8=Buffer.from(value,'utf8'); encoded=Buffer.concat([shortLen(value.length),shortLen(utf8.length),utf8,Buffer.alloc(1)]); }
    else { const utf16=Buffer.from(value,'utf16le'), n=Buffer.alloc(value.length>32767?4:2); if(n.length===2)n.writeUInt16LE(value.length);else{n.writeUInt16LE((value.length>>>16)|32768);n.writeUInt16LE(value.length&65535,2);} encoded=Buffer.concat([n,utf16,Buffer.alloc(2)]); }
    pieces.push(encoded); length+=encoded.length;
  }
  pieces.push(Buffer.alloc((4-length%4)%4));
  const strings=Buffer.concat(pieces), start=headerLen+offsets.length+styleOffsets.length;
  const styles=styleCount?original.subarray(original.readUInt32LE(24)):Buffer.alloc(0);
  header.writeUInt32LE(start,20); header.writeUInt32LE(styleCount?start+strings.length:0,24);
  header.writeUInt32LE(start+strings.length+styles.length,4);
  return Buffer.concat([header,offsets,styleOffsets,strings,styles]);
}
