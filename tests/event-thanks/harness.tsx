import React from 'react';
import {createRoot} from 'react-dom/client';
import {FamilyPortalThanks,HousePortalThanks}from '../../components/redesign/portal-thanks';
const house=new URLSearchParams(location.search).has('house');
const root=createRoot(document.getElementById('root')!);
const api={mountHouse(portalId:string){root.render(<React.StrictMode><main className="modern-ui"><HousePortalThanks portalId={portalId}/></main></React.StrictMode>);}};
declare global{interface Window{thanksHarness:typeof api}}
window.thanksHarness=api;
if(house)api.mountHouse('e1000000-0000-4000-8000-000000000001');else root.render(<React.StrictMode><main className="modern-ui"><FamilyPortalThanks/></main></React.StrictMode>);
