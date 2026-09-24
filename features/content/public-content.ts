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
    "Je schrijft je kinderen in en geeft jullie voorkeuren door. De organisatie deelt jullie in een loopgroep in, met maximaal 20 kinderen. Samen met een verantwoordelijke volwassene wandelen jullie langs deelnemende huizen in Duindorp. In de app verschijnt steeds één volgende poort. Jullie sluiten af bij de laatste poort met de eindshow en iets lekkers.",
  ],
  [
    "Voor welke leeftijd is de tocht?",
    "De tocht is voor kinderen die samen met een volwassene op pad gaan. Er zijn rustige werelden voor kleine avonturiers en spannende werelden voor kinderen die wel van een beetje kriebels houden. Een poort overslaan mag altijd.",
  ],
  [
    "Wat kost deelname?",
    "De bijdrage is €2,50 per kind. Daarmee verdelen we snoep onder de deelnemende huizen waar dat nodig is. Volwassen begeleiders lopen gratis mee. Na je inschrijving vind je de betaalinformatie in Mijn inschrijving. De betaling moet vóór 30 oktober bevestigd zijn om mee te kunnen doen.",
  ],
  [
    "Kunnen we samenlopen met vrienden?",
    "Ja. Deel jullie samenloopcode met vrienden of vul hun code in bij de inschrijving. Daarmee vraag je aan om samen te lopen. De organisatie beoordeelt het verzoek en controleert de ruimte: maximaal 20 kinderen per groep. Na goedkeuring vormen jullie één groep met dezelfde start, route en laatste poort. Tot die tijd is samenlopen nog niet bevestigd. De samenloopcode is iets anders dan de vaste G-code waarmee de organisatie jullie groep herkent.",
  ],
  [
    "Hoe laat begint en eindigt de avond?",
    "Op zaterdag 31 oktober 2026 ontvangen de eerste huizen vanaf 17:00 uur groepen. De avond duurt tot 21:00 uur en eindigt voor jullie bij de laatste poort, waar we ook voor iets lekkers zorgen. Niet iedereen begint of eindigt tegelijk: jullie krijgen een eigen bevestigde starttijd en startpunt. Volg de tijden en aanwijzingen in jullie persoonlijke omgeving.",
  ],
  [
    "Mogen we zelf een start- en eindtijd kiezen?",
    "Bij de inschrijving geef je jullie gewenste starttijd en gewenste eindtijd voor gewone poorten door. Dit zijn voorkeuren; de organisatie bevestigt de gezamenlijke afspraak voor jullie groep. Je kunt je voorkeuren in Mijn inschrijving aanpassen zolang de indeling open is. Daarna vraag je een wijziging aan bij de organisatie. Jullie stopgrens betekent: vanaf dat moment geen nieuwe gewone poort meer. De wandeling naar de laatste poort en de eindshow volgen daarna. De app houdt ook rekening met de algemene grens en de beschikbare tijd voor de finale.",
  ],
  [
    "Hoeveel huizen bezoeken we?",
    "De groepsleider kan vóór vertrek in Mijn groep een gewenst maximumaantal gewone huizen kiezen. Je kunt ook kiezen om door te lopen zolang er tijd is. Het gekozen aantal is een bovengrens, geen garantie: jullie starttijd, stopgrens en de beschikbare poorten bepalen wat haalbaar is. De laatste poort met de eindshow komt er altijd nog bij. Willen jullie onderweg eerder afronden, overleg dan via Messenger met de organisatie.",
  ],
  [
    "Hoe bereiken we de organisatie via Messenger?",
    "Log in en open Hulp van de organisatie in jullie persoonlijke omgeving. Daar stuur je een privébericht over bijvoorbeeld samenlopen, jullie start, een poort of eerder stoppen. Het gesprek blijft bewaard, zodat je later verder kunt praten. De Messenger laat zien of de organisatie beschikbaar is; een antwoord is niet altijd direct. Heb je nog geen account, gebruik dan de contactpagina. Bel bij direct gevaar 112.",
  ],
  [
    "Kan mijn kind een poort overslaan?",
    "Altijd. Is een poort te spannend, te donker of gewoon niet jullie ding? Dan slaan jullie die samen over. Je kind hoeft nooit iets te doen wat niet goed voelt. Een kind gaat niet alleen verder: de verantwoordelijke volwassene blijft bij de kinderen.",
  ],
  [
    "Wanneer ontvangen we de starttijd?",
    "Na bevestiging van de indeling verschijnen jullie starttijd, startpunt en verzamelinstructie in de persoonlijke omgeving. Je ontvangt hierover ook een e-mail. Een conceptindeling is nog niet zichtbaar en nog geen afspraak. Kom op jullie toegewezen tijd; pas na de aanwezigheidscontrole kan de groep vertrekken.",
  ],
  [
    "Kunnen we onze groep een eigen naam geven?",
    "Ja. De groepsleider kan in Mijn groep een eigen groepsnaam instellen en aanpassen. De vaste systeemcode, bijvoorbeeld G-01, blijft hetzelfde. Ook huiseigenaren kunnen hun poort een eigen naam geven; de P-code van hun poort blijft behouden.",
  ],
  [
    "Staan alle huisadressen op de openbare kaart?",
    "Nee. De openbare kaart laat de wijk zien, zonder deelnemende huisadressen. Tijdens de tocht ziet jullie bevoegde groep alleen het adres van de actuele bestemming. De laatste poort wordt zichtbaar wanneer jullie daarheen worden gestuurd. Meekijkers krijgen beperkte voortgang te zien, zonder toekomstige adressen of live locatie van kinderen.",
  ],
  [
    "Wat als onze telefoon tijdelijk geen verbinding heeft?",
    "De app bewaart de laatst bevestigde aanwijzing met de bijwerktijd. Zonder verbinding verschijnt geen nieuwe bestemming en wordt een bezoek niet automatisch afgerond. Blijf bij elkaar op een veilige plek en herstel de verbinding voordat jullie verdergaan. Neem contact op met de organisatie als dat niet lukt.",
  ],
  [
    "Wat nemen we mee?",
    "Kom in kleding waarin je kind prettig kan lopen en neem een snoepemmertje of tas mee. Neem een opgeladen telefoon mee voor de route en berichten. Een volwassene blijft de hele tocht bij de kinderen. Houd rekening met het weer en kies vooral wat voor jullie comfortabel voelt.",
  ],
  [
    "Kan een huis, portiek of bedrijf ook meedoen?",
    "Ja. Meld jullie woning, gezamenlijke entree, winkel of andere plek aan met contact- en adresgegevens. Bevestig daarna je e-mailadres met de inlogcode en vul jullie idee en overige gegevens aan in Mijn huis. Je kunt die gegevens later blijven bewerken. Een conceptaanmelding doet nog niet mee: de organisatie moet jullie poort eerst goedkeuren.",
  ],
  [
    "Hoe kan ik de avond steunen?",
    "Je kunt helpen met materiaal, vakkennis of een financiële bijdrage. Ook lokale bedrijven zijn van harte welkom. Laat via de sponsorpagina weten wat je wilt bijdragen, dan neemt de organisatie contact met je op.",
  ],
] as const;

export function getWorld(slug: string) {
  return worlds.find((world) => world.slug === slug);
}
