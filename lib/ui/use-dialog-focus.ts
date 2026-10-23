"use client";
import {useEffect,useRef} from "react";

/** Keeps keyboard navigation inside the existing modal and returns focus to its opener. */
export function useDialogFocus(open:boolean,selector:string,close:()=>void,busy=false){
 const latest=useRef({close,busy});
 useEffect(()=>{latest.current={close,busy};},[close,busy]);
 useEffect(()=>{
  if(!open)return;
  const modal=document.querySelector<HTMLElement>(selector);
  const opener=document.activeElement as HTMLElement|null;
  const overflow=document.body.style.overflow;
  document.body.style.overflow="hidden";
  const items=()=>Array.from(modal?.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),a[href],[tabindex="0"]')??[]);
  items()[0]?.focus();
  function key(event:KeyboardEvent){
   if(event.key==="Escape"&&!latest.current.busy){event.preventDefault();latest.current.close();}
   if(event.key!=="Tab")return;
   const list=items(),first=list[0],last=list.at(-1);
   if(event.shiftKey&&document.activeElement===first){event.preventDefault();last?.focus();}
   else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first?.focus();}
  }
  document.addEventListener("keydown",key);
  return()=>{document.removeEventListener("keydown",key);document.body.style.overflow=overflow;if(opener?.isConnected)opener.focus();};
 },[open,selector]);
}
