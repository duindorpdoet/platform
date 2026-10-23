"use client";
import type {ReactNode} from 'react';
import { createContext, useContext } from 'react';

export type EventDetails = { date: string | null; phase: string | null; priceCents: number | null; startsAt: string | null; endsAt: string | null };
export const EventContext = createContext<EventDetails>({ date: null, phase: null, priceCents: null, startsAt: null, endsAt: null });
export function EventProvider({value,children}:{value:EventDetails;children:ReactNode}) { return <EventContext value={value}>{children}</EventContext>; }
export function useEventDetails() {
  const event = useContext(EventContext);
  const date = event.date ? new Date(event.date + 'T12:00:00Z') : null;
  const valid = date && Number.isFinite(date.getTime());
  const format = (options: Intl.DateTimeFormatOptions) => valid ? new Intl.DateTimeFormat('nl-NL', { ...options, timeZone: 'Europe/Amsterdam' }).format(date) : 'Volgt';
  const time = (value: string | null) => value ? new Intl.DateTimeFormat('nl-NL', { timeZone: 'Europe/Amsterdam', hour: '2-digit', minute: '2-digit' }).format(new Date(value)) : 'Volgt';
  return { ...event, dateLong: format({ day: 'numeric', month: 'long', year: 'numeric' }), dateShort: format({ day: 'numeric', month: 'long' }), weekday: format({ weekday: 'long' }), day: format({ day: '2-digit' }), month: format({ month: '2-digit' }), monthShort: format({ month: 'short' }), year: format({ year: 'numeric' }), times: event.startsAt && event.endsAt ? `${time(event.startsAt)} – ${time(event.endsAt)}` : 'Tijden volgen', price: event.priceCents === null ? 'Bijdrage volgt' : new Intl.NumberFormat('nl-NL', { style: 'currency', currency: 'EUR' }).format(event.priceCents / 100) };
}
