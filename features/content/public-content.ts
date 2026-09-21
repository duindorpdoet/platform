export type World = {
  slug: string;
  name: string;
  subtitle: string;
  color: string;
  intensity: 1 | 2 | 3 | 4;
  story: string;
  warnings: string[];
};

export const worlds: World[] = [
  {
    slug: "heksenrijk",
    name: "Heksenrijk",
    subtitle: "Magie & spreuken",
    color: "#bf7afa",
    intensity: 2,
    story: "Diep tussen eeuwenoude bomen fluistert iemand je naam. Volg het paarse licht, maar raak geen spreuk kwijt. De heksen hebben vannacht bezoek verwacht.",
    warnings: ["Rook", "Donkere ruimtes"],
  },
  {
    slug: "dodenrijk",
    name: "Dodenrijk",
    subtitle: "Zielen & schaduwen",
    color: "#6bbcff",
    intensity: 3,
    story: "De stilte is bedrieglijk. Achter deze poorten ontwaken verhalen die al heel lang begraven lagen. Blijf bij elkaar: niet alles wat beweegt, leeft.",
    warnings: ["Acteurs", "Donkere ruimtes"],
  },
  {
    slug: "circuswereld",
    name: "Circuswereld",
    subtitle: "Illusie & chaos",
    color: "#ff9259",
    intensity: 3,
    story: "De voorstelling is al jaren afgelopen. Toch branden de lichten nog. Een laatste act wacht op jullie, in een circus waar niets is wat het lijkt.",
    warnings: ["Acteurs", "Schrikmomenten", "Harde geluiden"],
  },
  {
    slug: "besmette-zone",
    name: "Besmette zone",
    subtitle: "Gevaar & mutatie",
    color: "#a6dc54",
    intensity: 4,
    story: "Het experiment had nooit mogen beginnen. Het groene licht brandt nog en ergens gaat een alarm af. Kunnen jullie de besmetting stoppen?",
    warnings: ["Flitslicht", "Rook", "Harde geluiden"],
  },
  {
    slug: "geestenwereld",
    name: "Geestenwereld",
    subtitle: "Mist & verloren zielen",
    color: "#6edde5",
    intensity: 2,
    story: "Tussen de mist dwalen zielen die de weg naar huis zijn vergeten. Ze zijn niet allemaal gevaarlijk. Misschien heeft er één juist jullie hulp nodig.",
    warnings: ["Rook", "Donkere ruimtes"],
  },
  {
    slug: "vampierrijk",
    name: "Vampierrijk",
    subtitle: "Duisternis & oude verhalen",
    color: "#f56878",
    intensity: 4,
    story: "De deuren van het kasteel openen alleen na zonsondergang. De gastheer is charmant. Zijn gasten blijven meestal langer dan gepland.",
    warnings: ["Acteurs", "Schrikmomenten", "Bloed-effecten"],
  },
];

export const faq = [
  [
    "Hoe werkt de Halloween-tocht?",
    "Je schrijft je kinderen in en de organisatie maakt loopgroepen. Samen met volwassenen lopen jullie door Duindorp. Pas als iedereen klaar is, ziet de groep de volgende bestemming.",
  ],
  [
    "Voor welke leeftijd is de tocht?",
    "De tocht is voor kinderen onder begeleiding van een volwassene. De werelden verschillen in spanning. De definitieve leeftijdsrichtlijn volgt vóór de inschrijving opent.",
  ],
  [
    "Wat kost deelname?",
    "De huidige prijs is €2 per kind. Na inschrijving volgt de echte betaalinstructie. Alleen de organisatie kan een betaling bevestigen.",
  ],
  [
    "Kunnen we samenlopen met vrienden?",
    "Ja, je kunt een samenloopwens doorgeven. De organisatie houdt daar zo veel mogelijk rekening mee zonder de groepscapaciteit te overschrijden.",
  ],
  [
    "Kan mijn kind een poort overslaan?",
    "Altijd. Een ouder kan dat voor het eigen kind aangeven. De groep blijft bij elkaar en overslaan wordt nooit als een bezoek of scan getoond.",
  ],
  [
    "Wanneer ontvangen we de starttijd?",
    "Na publicatie van de groepsindeling vind je de toegewezen starttijd in je eigen omgeving. Tot die tijd blijft dit duidelijk een concept.",
  ],
  [
    "Hoe meld ik mijn huis aan?",
    "Via Huis aanmelden geef je thema, tijden, capaciteit en praktische kenmerken door. De organisatie beoordeelt de aanvraag voordat je huis een poort wordt.",
  ],
  [
    "Wat als de QR-code niet werkt?",
    "De groepsleider kan de korte poortcode gebruiken. Beide routes krijgen dezelfde servercontrole en geven nooit vanzelf de volgende bestemming vrij.",
  ],
] as const;

export function getWorld(slug: string) {
  return worlds.find((world) => world.slug === slug);
}
