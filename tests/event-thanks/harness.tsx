import React from 'react';
import {createRoot} from 'react-dom/client';
import {FamilyPortalThanks,HousePortalThanks}from '../../components/redesign/portal-thanks';
const house=new URLSearchParams(location.search).has('house');
createRoot(document.getElementById('root')!).render(<React.StrictMode><main className="modern-ui">{house?<HousePortalThanks portalId="e1000000-0000-4000-8000-000000000001"/>:<FamilyPortalThanks/>}</main></React.StrictMode>);
