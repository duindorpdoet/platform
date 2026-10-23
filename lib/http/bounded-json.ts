import { ApiError } from "./api";

export async function readBoundedJson(request: Request, maximumBytes = 16_384): Promise<unknown> {
  const reader=request.body?.getReader();
  if (!reader) throw new ApiError(400,"INVALID_JSON","Het verzoek mist geldige gegevens.");
  const parts:Uint8Array[]=[];
  let bytes=0;
  let timer:ReturnType<typeof setTimeout>|undefined;
  const deadline=new Promise<never>((_,reject)=>{
    timer=setTimeout(()=>{void reader.cancel();reject(new ApiError(408,"BODY_TIMEOUT","Het verzoek duurde te lang. Probeer opnieuw."));},5_000);
  });
  try {
    for (;;) {
      const {done,value}=await Promise.race([reader.read(),deadline]);
      if (done) break;
      bytes+=value.byteLength;
      if (bytes>maximumBytes) {await reader.cancel();throw new ApiError(413,"BODY_TOO_LARGE","Het verzoek bevat te veel gegevens.");}
      parts.push(value);
    }
    const body=new Uint8Array(bytes);let offset=0;
    for (const part of parts) {body.set(part,offset);offset+=part.byteLength;}
    try {return JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(body));}
    catch {throw new ApiError(400,"INVALID_JSON","Het verzoek mist geldige gegevens.");}
  } finally {clearTimeout(timer);reader.releaseLock();}
}
