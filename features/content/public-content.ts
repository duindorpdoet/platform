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
    "Je schrijft je kinderen in en wij maken kleine loopgroepen. Samen met een volwassene wandelen jullie langs versierde huizen, portieken en andere deelnemende plekken in Duindorp. Bij elke poort wacht een nieuwe verrassing en iets lekkers.",
  ],
  [
    "Voor welke leeftijd is de tocht?",
    "De tocht is voor kinderen die samen met een volwassene op pad gaan. Er zijn rustige werelden voor kleine avonturiers en spannende werelden voor kinderen die wel van een beetje kriebels houden. Een poort overslaan mag altijd.",
  ],
  [
    "Wat kost deelname?",
    "Meedoen kost €2 per kind. Na de inschrijving krijg je rustig uitgelegd hoe je kunt betalen. Een volwassene loopt gratis mee.",
  ],
  [
    "Kunnen we samenlopen met vrienden?",
    "Ja, geef bij de inschrijving aan met welk gezin of welke vriendjes jullie graag samenlopen. Wij proberen jullie bij elkaar te zetten. De groepsleider zorgt ervoor dat iedereen prettig en veilig mee kan.",
  ],
  [
    "Kan mijn kind een poort overslaan?",
    "Altijd. Is een poort te spannend, te donker of gewoon niet jullie ding? Dan slaan jullie die samen over. Je kind hoeft nooit iets te doen wat niet goed voelt.",
  ],
  [
    "Wanneer ontvangen we de starttijd?",
    "Zodra de groepen klaar zijn, zie je in jullie persoonlijke omgeving hoe laat en waar jullie starten. We sturen ook een duidelijke herinnering voor de avond.",
  ],
  [
    "Wat nemen we mee?",
    "Kom in kleding waarin je kind prettig kan lopen en neem een snoepemmertje of tas mee. Een volwassene blijft de hele tocht bij de kinderen. Houd rekening met het weer en kies vooral wat voor jullie comfortabel voelt.",
  ],
  [
    "Kan een huis, portiek of bedrijf ook meedoen?",
    "Ja. Een woning, gezamenlijke entree, winkel of andere plek in de wijk kan een poort worden. Meld jullie plek aan en vertel welk idee jullie hebben; de organisatie neemt daarna contact op om de mogelijkheden te bespreken.",
  ],
  [
    "Hoe kan ik de avond steunen?",
    "Je kunt helpen met materiaal, vakkennis of een financiële bijdrage. Ook lokale bedrijven zijn van harte welkom. Laat via de sponsorpagina weten wat je wilt bijdragen, dan neemt de organisatie contact met je op.",
  ],
] as const;

export function getWorld(slug: string) {
  return worlds.find((world) => world.slug === slug);
}
