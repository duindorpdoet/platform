/** Small, self-contained A4 PDF writer. QR modules remain vector paths at any print size. */
import QRCode from 'qrcode';
export type PosterData={gateName:string;gateCode:string;shortCode:string;arrivalUrl:string;eventDate:string;revision?:number};
export type PosterMode='colour'|'mono';
type EmbeddedFont={bytes:Uint8Array;widths:number[];ascent:number;descent:number;bbox:number[]};
let fonts:[EmbeddedFont,EmbeddedFont]|null=null;
let loading:Promise<void>|null=null;
function fontMetrics(bytes:Uint8Array):EmbeddedFont {
 const d=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),u16=(o:number)=>d.getUint16(o),i16=(o:number)=>d.getInt16(o),u32=(o:number)=>d.getUint32(o);
 const tables:Record<string,number>={};for(let i=0;i<u16(4);i++){const o=12+i*16;tables[String.fromCharCode(...bytes.slice(o,o+4))]=u32(o+8);}
 const head=tables.head,hhea=tables.hhea,hmtx=tables.hmtx,cmap=tables.cmap,units=u16(head+18),scale=(v:number)=>Math.round(v*1000/units);let format4=0;
 for(let i=0;i<u16(cmap+2);i++){const o=cmap+4+i*8,sub=cmap+u32(o+4);if(u16(sub)===4){format4=sub;if(u16(o)===3)break;}}
 const segs=u16(format4+6)/2,ends=format4+14,starts=ends+segs*2+2,deltas=starts+segs*2,ranges=deltas+segs*2;
 function glyph(c:number){for(let i=0;i<segs;i++)if(c<=u16(ends+i*2)){if(c<u16(starts+i*2))return 0;const delta=i16(deltas+i*2),range=u16(ranges+i*2);if(!range)return(c+delta)&65535;const g=u16(ranges+i*2+range+2*(c-u16(starts+i*2)));return g?(g+delta)&65535:0;}return 0;}
 const metrics=u16(hhea+34),widths=Array.from({length:95},(_,i)=>scale(u16(hmtx+Math.min(glyph(i+32),metrics-1)*4)));
 return {bytes,widths,ascent:scale(i16(hhea+4)),descent:scale(i16(hhea+6)),bbox:[36,38,40,42].map(o=>scale(i16(head+o)))};
}
export function setPosterFonts(regular:Uint8Array,bold:Uint8Array){fonts=[fontMetrics(regular),fontMetrics(bold)];}
export async function loadPosterFonts(){if(fonts)return;if(!loading)loading=Promise.all(['DejaVuSans.ttf','DejaVuSans-Bold.ttf'].map(async name=>{const response=await fetch('/print/fonts/'+name);if(!response.ok)throw new Error('PDF_FONT_UNAVAILABLE');return new Uint8Array(await response.arrayBuffer());})).then(([regular,bold])=>setPosterFonts(regular,bold)).catch(error=>{loading=null;throw error;});await loading;}
const W=595.28,H=841.89;
const ascii=(value:string)=>value.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[–—]/g,'-').replace(/[^\x20-\x7e]/g,'').replace(/([\\()])/g,'\\$1');
const n=(v:number)=>Number(v.toFixed(3));
export function createGatePosterPdf(data:PosterData,mode:PosterMode='colour'):Uint8Array {
 const colour=mode==='colour';const ink=colour?[.047,.078,.13]:[0,0,0],accent=colour?[.94,.52,.17]:[.18,.18,.18],light=colour?[.98,.95,.9]:[.96,.96,.96];
 let stream='';
 function fill(c:number[]){stream+=`${c.join(' ')} rg\n`;}
 function rect(x:number,y:number,w:number,h:number,c:number[]){fill(c);stream+=`${n(x)} ${n(H-y-h)} ${n(w)} ${n(h)} re f\n`;}
 function line(x1:number,y1:number,x2:number,y2:number,c:number[],width=1){stream+=`${c.join(' ')} RG ${width} w ${n(x1)} ${n(H-y1)} m ${n(x2)} ${n(H-y2)} l S\n`;}
 function text(txt:string,x:number,y:number,size:number,c=ink,bold=false){fill(c);stream+=`BT /${bold?'F2':'F1'} ${size} Tf 1 0 0 1 ${n(x)} ${n(H-y)} Tm (${ascii(txt)}) Tj ET\n`;}
 function center(txt:string,y:number,size:number,c=ink,bold=false){const clean=ascii(txt).replace(/\\([\\()])/g,'$1');const widths=fonts?.[bold?1:0].widths;const width=Array.from(clean).reduce((sum,ch)=>sum+(widths?widths[Math.max(0,Math.min(94,ch.charCodeAt(0)-32))]/1000:.52),0)*size;text(txt,(W-width)/2,y,size,c,bold);}

 function wrapped(txt:string,max:number){const result:string[]=[];let line='';for(const word of txt.split(/\s+/)){if((line+' '+word).trim().length>max&&line){result.push(line);line=word;}else line=(line+' '+word).trim();}if(line)result.push(line);return result;}
 rect(0,0,W,H,[1,1,1]);
 if(colour){rect(24,24,W-48,151,ink);rect(24,24,7,151,accent);}
 else{line(24,24,W-24,24,ink,.8);line(24,175,W-24,175,ink,.8);}
 const headerInk=colour?[1,1,1]:ink;
 text('DE DUINDORPSE POORTEN',49,58,12,headerInk,true);text('VAN HALLOWEEN',49,76,12,headerInk,true);
 text(new Date(data.eventDate+'T12:00:00Z').toLocaleDateString('nl-NL',{dateStyle:'full',timeZone:'Europe/Amsterdam'}).toUpperCase(),49,104,10,colour?[.97,.7,.43]:ink,true);
 text('Welkom bij deze poort',49,147,27,headerInk,true);
 const titleLines=wrapped(data.gateName,35).slice(0,2);titleLines.forEach((l,i)=>center(l,213+i*28,25,ink,true));
 center(`${data.gateCode}  |  SCAN BIJ AANKOMST`,titleLines.length>1?269:248,11,accent,true);
 const box=288,top=titleLines.length>1?283:266,left=(W-box)/2;
 // A four-module quiet zone surrounds the entire matrix, never a logo over the QR.
 const qr=QRCode.create(data.arrivalUrl,{errorCorrectionLevel:'M'});const count=qr.modules.size,unit=box/(count+8);
 rect(left,top,box,box,[1,1,1]);fill([0,0,0]);
 for(let r=0;r<count;r++){let start=-1;for(let c=0;c<=count;c++){const dark=c<count&&qr.modules.get(r,c);if(dark&&start<0)start=c;if(!dark&&start>=0){stream+=`${n(left+(start+4)*unit)} ${n(H-top-(r+5)*unit)} ${n((c-start)*unit+.015)} ${n(unit+.015)} re f\n`;start=-1;}}}
 const after=top+box;
 rect(85,after+9,W-170,63,light);center('LUKT SCANNEN NIET? VUL DEZE CODE IN:',after+29,9,ink,true);center(data.shortCode,after+56,23,ink,true);
 const instructions=[['1','Open de route van jullie groep.'],['2','Scan deze QR of vul de korte poortcode in.'],['3','Bevestig wie erbij is. De volgende poort verschijnt.']];
 const startY=after+95;instructions.forEach(([num,txt],i)=>{const y=startY+i*30;rect(54,y-13,20,20,accent);text(num,60,y+1,11,[1,1,1],true);text(txt,86,y+1,11,ink,i===2);});
 line(48,777,W-48,777,colour?[.85,.79,.7]:[.75,.75,.75]);center('Blijf samen met jullie groep. Een te spannende poort overslaan mag.',798,9,ink);
 center(`BEVESTIG JULLIE AANKOMST IN DE ROUTE  |  V${data.revision||1}`,820,7,ink,true);
 const objects=[
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${W} ${H}] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>`,
  fonts?`<< /Type /Font /Subtype /TrueType /BaseFont /DejaVuSans /FirstChar 32 /LastChar 126 /Widths [${fonts[0].widths.join(' ')}] /Encoding /WinAnsiEncoding /FontDescriptor 8 0 R >>`:'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  fonts?`<< /Type /Font /Subtype /TrueType /BaseFont /DejaVuSans-Bold /FirstChar 32 /LastChar 126 /Widths [${fonts[1].widths.join(' ')}] /Encoding /WinAnsiEncoding /FontDescriptor 10 0 R >>`:'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>',
  `<< /Length ${stream.length} >>\nstream\n${stream}endstream`,
  `<< /Title (${ascii(`QR-poster ${data.gateCode} - ${data.gateName}`)}) /Author (Duindorp Doet) /Subject (Printbare A4 QR-poster - ${colour?'kleur':'zwart-wit'}) >>`
 ];
 if(fonts)fonts.forEach((font,index)=>{const name=index?'DejaVuSans-Bold':'DejaVuSans';const hex=Array.from(font.bytes,b=>b.toString(16).padStart(2,'0')).join('')+'>';objects.push(`<< /Type /FontDescriptor /FontName /${name} /Flags 32 /FontBBox [${font.bbox.join(' ')}] /ItalicAngle 0 /Ascent ${font.ascent} /Descent ${font.descent} /CapHeight ${font.ascent} /StemV 80 /FontFile2 ${index?11:9} 0 R >>`);objects.push(`<< /Length ${hex.length} /Length1 ${font.bytes.length} /Filter /ASCIIHexDecode >>\nstream\n${hex}\nendstream`);});
 let pdf='%PDF-1.4\n';const offsets=[0];objects.forEach((obj,i)=>{offsets.push(pdf.length);pdf+=`${i+1} 0 obj\n${obj}\nendobj\n`;});const xref=pdf.length;pdf+=`xref\n0 ${objects.length+1}\n0000000000 65535 f \n`;offsets.slice(1).forEach(o=>{pdf+=`${String(o).padStart(10,'0')} 00000 n \n`;});pdf+=`trailer\n<< /Size ${objects.length+1} /Root 1 0 R /Info 7 0 R >>\nstartxref\n${xref}\n%%EOF\n`;return new TextEncoder().encode(pdf);
}
