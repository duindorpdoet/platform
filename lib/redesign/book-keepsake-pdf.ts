import type { BookSnapshot } from '@/lib/poortenboek/model';
import { avatarOptions, lanternColors, lanternShapes } from '@/lib/poortenboek/v2';

type Font = {bytes: Uint8Array; widths: number[]; ascent: number; descent: number; bbox: number[]};
type RGB = [number, number, number];
let fonts: [Font, Font] | null = null;
let loading: Promise<void> | null = null;
const W = 595.28, H = 841.89;
const navy: RGB = [.055,.09,.15], amber: RGB = [.72,.39,.13], muted: RGB = [.34,.39,.46], paper: RGB = [.985,.975,.95];
const palette: Record<string, RGB> = {amber:[.9,.55,.13],cyan:[.12,.64,.75],violet:[.56,.36,.8],emerald:[.18,.62,.43],rose:[.84,.34,.5],moonlight:[.55,.65,.8]};
const latin = (value: unknown) => String(value ?? '').replace(/[–—−]/g,'-').replace(/[“”]/g,'"').replace(/[‘’]/g,"'").replace(/\u00a0/g,' ').split('').map(c => c.charCodeAt(0) <= 255 ? c : c.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[^\x20-\xff]/g,'')).join('').replace(/[\x00-\x1f\x7f-\x9f]/g,'');
const escaped = (value: unknown) => latin(value).replace(/([\\()])/g,'\\$1');
const bytes = (value: string) => Uint8Array.from(value, c=>c.charCodeAt(0)&255);
const join = (parts: Uint8Array[]) => {const result=new Uint8Array(parts.reduce((n,p)=>n+p.length,0));let offset=0;for(const part of parts){result.set(part,offset);offset+=part.length;}return result;};
const n=(value:number)=>Number(value.toFixed(3));
function readFont(data: Uint8Array): Font {
 const d=new DataView(data.buffer,data.byteOffset,data.byteLength),u16=(o:number)=>d.getUint16(o),i16=(o:number)=>d.getInt16(o),u32=(o:number)=>d.getUint32(o),tables:Record<string,number>={};
 for(let i=0;i<u16(4);i++){const o=12+i*16;tables[String.fromCharCode(...data.slice(o,o+4))]=u32(o+8);}
 const head=tables.head,hhea=tables.hhea,hmtx=tables.hmtx,cmap=tables.cmap,units=u16(head+18),scale=(v:number)=>Math.round(v*1000/units);let cmap4=0;
 for(let i=0;i<u16(cmap+2);i++){const o=cmap+4+i*8,sub=cmap+u32(o+4);if(u16(sub)===4){cmap4=sub;if(u16(o)===3)break;}}
 if(!cmap4)throw new Error('PDF_FONT_UNAVAILABLE');
 const segs=u16(cmap4+6)/2,ends=cmap4+14,starts=ends+segs*2+2,deltas=starts+segs*2,ranges=deltas+segs*2;
 function glyph(c:number){for(let i=0;i<segs;i++)if(c<=u16(ends+i*2)){if(c<u16(starts+i*2))return 0;const delta=i16(deltas+i*2),range=u16(ranges+i*2);if(!range)return(c+delta)&65535;const g=u16(ranges+i*2+range+2*(c-u16(starts+i*2)));return g?(g+delta)&65535:0;}return 0;}
 const metrics=u16(hhea+34),widths=Array.from({length:224},(_,i)=>scale(u16(hmtx+Math.min(glyph(i+32),metrics-1)*4)));
 return {bytes:data,widths,ascent:scale(i16(hhea+4)),descent:scale(i16(hhea+6)),bbox:[36,38,40,42].map(o=>scale(i16(head+o)))};
}
export function setBookKeepsakeFonts(regular: Uint8Array, bold: Uint8Array){fonts=[readFont(regular),readFont(bold)];}
export async function loadBookKeepsakeFonts(){
 if(fonts)return;
 if(!loading)loading=Promise.all(['DejaVuSans.ttf','DejaVuSans-Bold.ttf'].map(async name=>{const response=await fetch('/print/fonts/'+name);if(!response.ok)throw new Error('PDF_FONT_UNAVAILABLE');return new Uint8Array(await response.arrayBuffer());})).then(([regular,bold])=>setBookKeepsakeFonts(regular,bold)).catch(error=>{loading=null;throw error;});
 await loading;
}
function formattedDate(value:string){const date=new Date(/^\d{4}-\d{2}-\d{2}$/.test(value)?`${value}T12:00:00+01:00`:value);return Number.isFinite(date.getTime())?new Intl.DateTimeFormat('nl-NL',{day:'numeric',month:'long',year:'numeric',timeZone:'Europe/Amsterdam'}).format(date):'Evenementdatum volgt';}
function formattedTime(value:string){const date=new Date(value);return Number.isFinite(date.getTime())?new Intl.DateTimeFormat('nl-NL',{hour:'2-digit',minute:'2-digit',timeZone:'Europe/Amsterdam'}).format(date):'Tijd niet bekend';}

/** Generates a personal, address-free PDF. Only snapshot.journey.seals supply visits. */
export function createBookKeepsakePdf(snapshot: BookSnapshot): Uint8Array {
 if(!fonts)throw new Error('PDF_FONT_UNAVAILABLE');
 const selectedFonts=fonts,streams:string[]=[];let stream='';
 const width=(value:unknown,size:number,bold=false)=>Array.from(latin(value)).reduce((sum,c)=>sum+(selectedFonts[bold?1:0].widths[Math.max(0,Math.min(223,c.charCodeAt(0)-32))]??0)/1000,0)*size;
 function colour(c:RGB){stream+=`${c.join(' ')} rg\n`;}
 function rect(x:number,y:number,w:number,h:number,c:RGB){colour(c);stream+=`${n(x)} ${n(H-y-h)} ${n(w)} ${n(h)} re f\n`;}
 function line(x:number,y:number,x2:number,y2:number,c:RGB=amber,stroke=.8){stream+=`${c.join(' ')} RG ${stroke} w ${n(x)} ${n(H-y)} m ${n(x2)} ${n(H-y2)} l S\n`;}
 function text(value:unknown,x:number,y:number,size:number,c:RGB=navy,bold=false){colour(c);stream+=`BT /${bold?'F2':'F1'} ${size} Tf 1 0 0 1 ${n(x)} ${n(H-y)} Tm (${escaped(value)}) Tj ET\n`;}
 function center(value:unknown,y:number,size:number,c:RGB=navy,bold=false){text(value,(W-width(value,size,bold))/2,y,size,c,bold);}
 function fit(value:unknown,max:number,size:number,bold=false){return Math.max(9,Math.min(size,size*max/Math.max(width(value,size,bold),1)));}
 function wrap(value:unknown,maxWidth:number,size:number,bold=false){const out:string[]=[];let line='';for(const word of latin(value).split(/\s+/)){if(width(word,size,bold)>maxWidth){if(line){out.push(line);line='';}let fragment='';for(const char of word){if(fragment&&width(fragment+char,size,bold)>maxWidth){out.push(fragment);fragment=char;}else fragment+=char;}line=fragment;continue;}const candidate=line?line+' '+word:word;if(line&&width(candidate,size,bold)>maxWidth){out.push(line);line=word;}else line=candidate;}if(line)out.push(line);return out;}
 function paragraph(value:unknown,x:number,y:number,maxWidth:number,size=11,leading=17,c:RGB=muted,bold=false){const lines=wrap(value,maxWidth,size,bold);lines.forEach((l,i)=>text(l,x,y+i*leading,size,c,bold));return y+lines.length*leading;}
 function polygon(points:number[][],c:RGB){colour(c);stream+=points.map(([x,y],i)=>`${n(x)} ${n(H-y)} ${i?'l':'m'}`).join(' ')+' h f\n';}
 function star(x:number,y:number,r:number,c:RGB=amber){polygon(Array.from({length:10},(_,i)=>{const angle=-Math.PI/2+i*Math.PI/5,radius=i%2?r*.42:r;return [x+Math.cos(angle)*radius,y+Math.sin(angle)*radius];}),c);}
 function lantern(x:number,y:number,shape:string,c:RGB){
  line(x-13,y-30,x+13,y-30,navy,2);line(x-10,y-31,x-8,y-39,navy,2);line(x-8,y-39,x+8,y-39,navy,2);line(x+8,y-39,x+10,y-31,navy,2);
  if(shape==='moon'){polygon([[x-17,y-24],[x-23,y-9],[x-16,y+12],[x+4,y+21],[x+18,y+10],[x+1,y+9],[x-7,y-4],[x-2,y-18],[x+11,y-26]],c);}
  else if(shape==='crystal'){polygon([[x,y-27],[x+20,y-5],[x+11,y+19],[x-11,y+19],[x-20,y-5]],c);line(x,y-27,x,y+19,navy,.7);line(x-20,y-5,x+20,y-5,navy,.7);}
  else if(shape==='tower'){polygon([[x-16,y-25],[x-16,y-33],[x-6,y-33],[x-6,y-25],[x+5,y-25],[x+5,y-33],[x+16,y-33],[x+16,y+19],[x-16,y+19]],navy);rect(x-9,y-15,18,25,c);}
  else {polygon([[x-16,y-26],[x+16,y-26],[x+22,y+16],[x-22,y+16]],c);line(x-18,y-26,x+18,y-26,navy,3);line(x-23,y+18,x+23,y+18,navy,3);line(x-13,y-25,x-17,y+17,navy,1);line(x+13,y-25,x+17,y+17,navy,1);}
  star(x,y-3,7,shape==='tower'?[1,1,1]:navy);
 }
 const seals=[...snapshot.journey.seals].sort((a,b)=>new Date(a.earnedAt).getTime()-new Date(b.earnedAt).getTime());
 const ended=snapshot.journey.complete||Boolean(snapshot.farewell?.endedAt),firstName=latin(snapshot.firstName).trim()||'Avonturier',team=snapshot.election.winner||'Jullie teamnaam wordt nog gekozen';
 function frame(page:number,total:number){rect(0,0,W,H,[1,1,1]);rect(22,22,W-44,H-44,paper);line(34,34,W-34,34);line(34,H-34,W-34,H-34);line(34,34,34,H-34);line(W-34,34,W-34,H-34);star(48,48,5);star(W-48,48,5);text('DE DUINDORPSE POORTEN VAN HALLOWEEN',51,77,9,navy,true);text(formattedDate(snapshot.eventDate),51,94,9,muted);line(51,112,W-51,112,[.85,.81,.74]);center(`Persoonlijk Poortenboek - ${page} / ${total}`,786,8,muted);}
 const visitPages:Array<Array<{seal:typeof seals[number];titles:string[];height:number}>>=[];let used=0;for(const seal of seals){const titles=wrap(seal.presentation.publicName,W-174,11,true),height=Math.max(56,30+titles.length*14);if(!visitPages.length||used+height+9>490){visitPages.push([]);used=0;}visitPages.at(-1)!.push({seal,titles,height});used+=height+9;}const listPages=visitPages.length,total=1+listPages;
 frame(1,total);
 center(ended?'JOUW NACHT OM TE BEWAREN':'JOUW AVONTUUR, TOT NU TOE',153,10,amber,true);
 star(W/2,187,13);
 center(firstName,247,fit(firstName,W-120,48,true),navy,true);
 center(ended?'Jij bracht licht in Duindorp.':'Jouw verhaal is al begonnen.',282,20,navy,true);
 const intro=ended?'Samen op pad in Duindorp. Dit is jouw persoonlijke herinnering aan een bijzondere avond.':'Deze bewaarkaart toont de zegels die jij al hebt verzameld. Je kunt later opnieuw een kaart downloaden.';
 const introLines=wrap(intro,W-146,11);introLines.forEach((l,i)=>center(l,310+i*17,11,muted));
 const count=seals.length,worldCount=new Set(seals.filter(s=>!s.finale).map(s=>s.presentation.world)).size,chapterCount=new Set(snapshot.journey.chapters.map(c=>c.chapter)).size;
 const stats=[{number:String(count),label:count===1?'poortzegel':'poortzegels'},{number:String(worldCount),label:worldCount===1?'wereld bereikt':'werelden bereikt'},{number:String(chapterCount),label:'hoofdstukken open'}];
 stats.forEach((item,i)=>{const x=51+i*166;rect(x,365,159,78,[.947,.928,.895]);text(item.number,x+17,400,26,navy,true);text(item.label,x+17,423,9,muted);});
 text('JOUW TEAM',55,477,8,amber,true);paragraph(team,55,500,285,fit(team,285,15,true),19,navy,true);
 text('JOUW VERSCHIJNING',55,546,8,amber,true);paragraph(avatarOptions.find(a=>a.id===snapshot.identity.avatarId)?.label??'Avonturier',55,568,285,14,18,navy,true);
 const lc=palette[snapshot.identity.lanternColor]??palette.amber;lantern(466,513,snapshot.identity.lanternShape,lc);
 const lanternLabel=lanternShapes.find(s=>s.id===snapshot.identity.lanternShape)?.label??'Lantaarn',colourLabel=lanternColors.find(c=>c.id===snapshot.identity.lanternColor)?.label??'Amber';
 text('JOUW LICHT',370,568,8,amber,true);paragraph(`${lanternLabel} - ${colourLabel}`,370,589,170,10,16,navy);
 line(55,626,W-55,626,[.85,.81,.74]);
 text('DIE AVOND NEEM JIJ MEE',55,652,8,amber,true);
 const worlds=[...new Set(seals.map(s=>s.presentation.world))];
 paragraph(worlds.length?worlds.join('  /  '):ended?'Jouw eigen avontuur telt. Ook de voorpret en samen op pad zijn horen bij jouw avond.':'Jouw eerste poortzegel wacht nog op je. Ook de voorpret hoort bij jouw avontuur.',55,677,W-110,11,18,navy);
 paragraph(ended?'Jouw avond is van jou. Samen op pad zijn telt. Jij hoort bij het verhaal van Duindorp.':'Je hoeft niet naar binnen als je dat spannend vindt. Bij aankomst bij de poort hoor jij er gewoon bij. Blijf samen met je volwassene.',55,733,W-110,9,14,muted);
 streams.push(stream);
 for(let p=0;p<listPages;p++){
  stream='';frame(p+2,total);text('JOUW VERZAMELDE POORTZEGELS',55,152,9,amber,true);text(firstName,55,187,fit(firstName,W-110,28,true),navy,true);paragraph('Iedere zegel hieronder hoort bij een poort die jij met je groep hebt bereikt. Ook als je de spannende beleving liever overslaat, hoor jij erbij.',55,215,W-110,10,16,muted);
  let rowY=270;visitPages[p].forEach(({seal,titles,height},i)=>{const y=rowY;rect(55,y,W-110,height,i%2?[.974,.964,.94]:[.944,.93,.9]);star(77,y+25,10,seal.finale?amber:(palette[seal.presentation.color]??amber));titles.forEach((l,j)=>text(l,99,y+18+j*14,11,navy,true));text(`${seal.finale?'Finalezegel':seal.presentation.world} - ${formattedTime(seal.earnedAt)}`,99,y+height-10,8.5,muted);rowY+=height+9;});
  streams.push(stream);
 }
 const objects:Array<string|Uint8Array>=[];const add=(obj:string|Uint8Array)=>{objects.push(obj);return objects.length;};
 const catalog=add(''),pages=add('');const fontIds=selectedFonts.map((font,index)=>{const fontId=add(''),descriptor=add(''),file=add(join([bytes(`<< /Length ${font.bytes.length} /Length1 ${font.bytes.length} >>\nstream\n`),font.bytes,bytes('\nendstream')])),name=index?'DejaVuSans-Bold':'DejaVuSans';objects[fontId-1]=`<< /Type /Font /Subtype /TrueType /BaseFont /${name} /FirstChar 32 /LastChar 255 /Widths [${font.widths.join(' ')}] /Encoding /WinAnsiEncoding /FontDescriptor ${descriptor} 0 R >>`;objects[descriptor-1]=`<< /Type /FontDescriptor /FontName /${name} /Flags 32 /FontBBox [${font.bbox.join(' ')}] /ItalicAngle 0 /Ascent ${font.ascent} /Descent ${font.descent} /CapHeight ${font.ascent} /StemV 80 /FontFile2 ${file} 0 R >>`;return fontId;});
 const pageIds=streams.map(content=>{const data=bytes(content),contentId=add(join([bytes(`<< /Length ${data.length} >>\nstream\n`),data,bytes('endstream')]));return add(`<< /Type /Page /Parent ${pages} 0 R /MediaBox [0 0 ${W} ${H}] /Resources << /Font << /F1 ${fontIds[0]} 0 R /F2 ${fontIds[1]} 0 R >> >> /Contents ${contentId} 0 R >>`);});
 objects[catalog-1]=`<< /Type /Catalog /Pages ${pages} 0 R >>`;objects[pages-1]=`<< /Type /Pages /Kids [${pageIds.map(id=>`${id} 0 R`).join(' ')}] /Count ${pageIds.length} >>`;
 const info=add(`<< /Title (${escaped(`Het Poortenboek van ${firstName}`)}) /Author (Duindorp Doet) /Subject (Persoonlijke bewaarkaart - ${ended?'afgeronde avond':'tussenstand'}) >>`);
 const parts=[bytes('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')],offsets=[0];let offset=parts[0].length;
 objects.forEach((object,index)=>{offsets.push(offset);const data=join([bytes(`${index+1} 0 obj\n`),typeof object==='string'?bytes(object):object,bytes('\nendobj\n')]);parts.push(data);offset+=data.length;});
 const xref=`xref\n0 ${objects.length+1}\n0000000000 65535 f \n${offsets.slice(1).map(o=>String(o).padStart(10,'0')+' 00000 n \n').join('')}trailer\n<< /Size ${objects.length+1} /Root ${catalog} 0 R /Info ${info} 0 R >>\nstartxref\n${offset}\n%%EOF\n`;parts.push(bytes(xref));return join(parts);
}
