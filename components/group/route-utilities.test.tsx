import React from 'react';
import {describe,it,expect} from 'vitest';
import {renderToStaticMarkup} from 'react-dom/server';
import {DestinationWarnings} from './route-utilities';
import {VisitInformationFields,visitInformationDraft} from '../portal/visit-information';

describe('practical information without invented assurances',()=>{
 it('distinguishes missing disclosure from explicitly no effects',()=>{
  const missing=renderToStaticMarkup(<DestinationWarnings portal={{}}/>);
  expect(missing).toContain('nog niet volledig doorgegeven');expect(missing).not.toContain('Geen extra effecten doorgegeven');
  const none=renderToStaticMarkup(<DestinationWarnings portal={{warnings:{smoke:false,flashes:false,sound:false,actors:false,allergens:false}}}/>);
  expect(none).toContain('Geen extra effecten doorgegeven');expect(none).not.toContain('nog niet volledig doorgegeven');
 });
 it('keeps legacy known effects visible while marking the remaining information unknown',()=>{
  const partial=renderToStaticMarkup(<DestinationWarnings portal={{warnings:{smoke:true},warningNotes:'Vraag ons bij aankomst',accessibility:'steps',accessibilityNotes:'Twee treden'}}/>);
  expect(partial).toContain('Rook of nevel');expect(partial).toContain('nog niet volledig doorgegeven');expect(partial).toContain('Twee treden');
  expect(partial).toContain('Ieder aanwezig kind');expect(partial).not.toContain('Flitslicht');
 });
 it('does not restore legacy unchecked boxes as a declaration of no effects',()=>{
  const value=visitInformationDraft({warnings:{smoke:false,flashes:false,sound:false,actors:false,allergens:false}});
  const markup=renderToStaticMarkup(<VisitInformationFields value={value} onChange={()=>{}}/>);
  expect(markup).toContain('<option value="unknown" selected="">');expect(value.warningDisclosure).toBe('unknown');
 });
});
