import {z} from 'zod';
import {guidanceReturnPath,GUIDANCE_VERSION} from './guidance-state';
export const guidanceRequest = z.discriminatedUnion('action',[
  z.object({action:z.literal('acknowledge')}).strict(),
  z.object({action:z.literal('tutorial'),role:z.enum(['parent','house']),version:z.literal(GUIDANCE_VERSION),index:z.number().int().min(0).max(13),completed:z.boolean().optional(),returnPath:z.string().max(4096).optional()}).strict(),
]).transform((data,ctx)=>{
  if(data.action==='acknowledge')return data;
  try{return {...data,returnPath:guidanceReturnPath(data.returnPath,data.role)};}
  catch{ctx.addIssue({code:'custom',path:['returnPath'],message:'Ongeldige bestemming.'});return z.NEVER;}
});
