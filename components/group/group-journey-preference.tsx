export function GroupJourneyPreference({ groupId }: { groupId: string; onSaved?: () => Promise<void> }) {
  return <section className="participant-card group-journey-card" aria-labelledby={`group-journey-title-${groupId}`}>
    <p className="participant-eyebrow">Jullie tocht</p><h2 id={`group-journey-title-${groupId}`}>Samen zo veel mogelijk huizen bezoeken</h2>
    <p>Jullie route bevat zo veel mogelijk verschillende, geschikte huizen binnen jullie afgesproken tijden. De werkelijke looptijd, ontvangsttijden en beschikbare plaatsen bepalen wat past. Daarna sluit jullie groep af bij P-38.</p>
    <p>Jullie startafspraak en geldende tijdgrenzen blijven behouden. Een wijziging tijdens de tocht bespreek je via Messenger met de organisatie.</p>
  </section>;
}
