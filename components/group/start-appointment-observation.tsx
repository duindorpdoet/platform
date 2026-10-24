"use client";
import {useEffect,useRef,type RefObject} from 'react';
import {recordReadiness,type ReadinessKind} from '@/lib/redesign/readiness';
export function useAccountObservation(kind:ReadinessKind,subjectId?:string|null) {
  useEffect(()=>{if(!subjectId)return;let saved=false,pending=false;const key=crypto.randomUUID();const check=async()=>{if(saved||pending||document.hidden)return;pending=true;try{await recordReadiness({kind,subjectId,check:'account_opened',key});saved=true;}catch{}finally{pending=false;}};void check();window.addEventListener('focus',check);document.addEventListener('visibilitychange',check);return()=>{window.removeEventListener('focus',check);document.removeEventListener('visibilitychange',check);};},[kind,subjectId]);
}
export function useStartAppointmentObservation(ref:RefObject<HTMLElement|null>,groupId?:string,revision?:string|null) {
  const observed=useRef('');
  useEffect(()=>{
    const element=ref.current;if(!element||!groupId||!revision)return;
    let pending=false;const key=crypto.randomUUID();
    const check=async()=>{
      if(pending||observed.current===`${groupId}:${revision}`||document.hidden||document.documentElement.dataset.participantGuidanceActive==='true')return;
      const box=element.getBoundingClientRect(),visible=Math.min(box.bottom,window.innerHeight)-Math.max(box.top,0);
      if(!box.width||visible<Math.min(64,box.height/2))return;
      pending=true;try{await recordReadiness({kind:'group',subjectId:groupId,check:'start_time_seen',revision,key});observed.current=`${groupId}:${revision}`;}catch{}finally{pending=false;}
    };
    const observer=typeof IntersectionObserver!=='undefined'?new IntersectionObserver(()=>void check(),{threshold:[0,.25,.5,1]}):null;
    observer?.observe(element);for(const event of ['focus','scroll','poorten-guidance-status'])window.addEventListener(event,check,true);document.addEventListener('visibilitychange',check);void check();
    return()=>{observer?.disconnect();for(const event of ['focus','scroll','poorten-guidance-status'])window.removeEventListener(event,check,true);document.removeEventListener('visibilitychange',check);};
  },[ref,groupId,revision]);
}

export function ObservedStartTime({groupId,revision,children}:{groupId?:string;revision?:string|null;children:React.ReactNode}) {
  const ref=useRef<HTMLHeadingElement>(null);useStartAppointmentObservation(ref,groupId,revision);return <h2 ref={ref}>{children}</h2>;
}
