import fs from 'node:fs/promises';
import path from 'node:path';
import { fail,uuid } from './core.js';

export const ROOT=process.env.LEGAL_STORAGE_DIR||'/opt/aimuza/legal';
export function filePath(key) {return path.join(ROOT,uuid(key));}
export function detectFile(buffer,name) {
  if(buffer.subarray(0,5).toString()==='%PDF-' && /\.pdf$/i.test(name)) return 'application/pdf';
  if(buffer.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])) && /\.png$/i.test(name)) return 'image/png';
  if(buffer[0]===255 && buffer[1]===216 && buffer[2]===255 && /\.jpe?g$/i.test(name)) return 'image/jpeg';
  if(buffer.readUInt32LE(0)===0x04034b50 && /\.docx$/i.test(name)) {
    // Inspect the central directory without inflating untrusted ZIP entries.
    let end=-1;
    for(let i=buffer.length-22;i>=Math.max(0,buffer.length-65557);i--) if(buffer.readUInt32LE(i)===0x06054b50){end=i;break;}
    if(end<0) throw fail(400,'Повреждённый DOCX');
    const entries=buffer.readUInt16LE(end+10),offset=buffer.readUInt32LE(end+16);
    if(entries>2000 || offset>=end) throw fail(400,'Слишком сложный DOCX');
    let pos=offset,total=0;const names=[];
    for(let i=0;i<entries;i++) {
      if(pos+46>end || buffer.readUInt32LE(pos)!==0x02014b50) throw fail(400,'Повреждённый DOCX');
      const flags=buffer.readUInt16LE(pos+8),packed=buffer.readUInt32LE(pos+20),size=buffer.readUInt32LE(pos+24);
      const len=buffer.readUInt16LE(pos+28),extra=buffer.readUInt16LE(pos+30),comment=buffer.readUInt16LE(pos+32);
      const next=pos+46+len+extra+comment;
      if(next>end || flags&1 || size>100*1024*1024 || size>Math.max(packed,1)*200) throw fail(400,'Недопустимый DOCX');
      const n=buffer.subarray(pos+46,pos+46+len).toString('utf8');
      if(n.includes('..')||/vba|activex|embeddings|\.exe$|\.js$/i.test(n)) throw fail(400,'DOCX содержит запрещённые объекты');
      names.push(n);total+=size;pos=next;
    }
    if(total>100*1024*1024 || !names.includes('word/document.xml') || !names.includes('[Content_Types].xml')) throw fail(400,'Некорректный DOCX');
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  throw fail(400,'Разрешены PDF, DOCX, JPEG и PNG с корректным расширением');
}
export async function validateFile(file) {
  if(file.size<8 || file.size>25*1024*1024) throw fail(400,'Размер файла: от 8 байт до 25 МиБ');
  const buffer=await fs.readFile(file.path);
  return {buffer,mime:detectFile(buffer,file.originalname)};
}
