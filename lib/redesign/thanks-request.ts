import {z} from 'zod';
export const closedThanksRequest=z.object({
 kind:z.enum(['all','personal']),portalId:z.uuid().nullable().default(null),
 choice:z.enum(['beautiful','welcome','treats']).nullable().default(null),
 message:z.string().trim().max(500).default(''),requestKey:z.uuid(),submissionId:z.uuid().nullable().default(null),
}).strict().superRefine((input,ctx)=>{
 if(input.kind==='all'&&(input.portalId!==null||input.choice!==null))ctx.addIssue({code:'custom',path:['portalId'],message:'Een algemeen bedankje heeft geen losse poort.'});
 if(input.kind==='personal'&&(input.portalId===null||input.choice===null))ctx.addIssue({code:'custom',path:['portalId'],message:'Kies een poort en reactie.'});
});
