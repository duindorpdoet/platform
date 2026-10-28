# Persoonsnamen en groepscontext

## Vastgestelde oorzaak

`app_private.messenger_subject_metadata` selecteerde voor groepsgesprekken uitsluitend `walking_groups.system_code`, `display_name` en `code`. Als `display_name` ontbrak, werden zowel de zichtbare naam als het contextveld de groepscode. `MessengerInbox` combineerde vervolgens deze twee velden. De profielnaam werd nergens geraadpleegd. De berichtafzender gebruikte bovendien de gesprekstitel in plaats van de identiteit van de afzonderlijke afzender.

`app_private.enqueue_together_request_email` stopte dezelfde groepscontext in `groupName` en `headGroup`. `group_merge_approved` gebruikte `headGroup` in de zin “De samenvoeging met …”. Dit was een fout in het veldcontract tussen database en template, geen bewijs van een verkeerd opgeslagen persoonsnaam.

De productiecontrole van de drie opgegeven inboxvoorbeelden vond telkens een bruikbare `profiles.display_name`, exact gelijk aan de oorspronkelijke `registration_drafts.payload.adult.name` van het contactaccount. De wandelgroepen hadden geen `display_name`. De inventarisatie vond onder 177 profielen 37 ontbrekende namen en geen opgeslagen G-code als persoonsnaam; ook gezelschapslabels en oorspronkelijke contactnamen bevatten geen G-code. Ontbrekende profielen worden niet blind aangevuld: alleen het oorspronkelijke contact van dat specifieke account kan als eenduidige leesfallback dienen.

De twee bestaande samenloopmails voor `SL-2026-9VPTQB` bevatten groepscontext zonder persoonsvelden. Eén was bezorgd, één had de historische status `unknown`. Deze hotfix verandert beide records niet en herhaalt geen verzending.

## Herstel

De private resolver kiest een bruikbare accountprofielnaam, anders de eenduidige oorspronkelijke contactnaam van de eigen primaire contactpersoon. Een ander volwassen gezinslid krijgt nooit automatisch die naam. Groepscodes, e-mailadressen, UUID's en onbruikbare invoer zijn geen persoonsnamen. Zonder bron wordt “Deelnemer” getoond. Accenten en tussenvoegsels blijven behouden.

De projecties leveren expliciete velden: `personName`, `householdLabel`, `groupCode`, `groupName`, `portalName` en per bericht `senderName`. De inbox en deelnemerchat gebruiken de persoon als primaire naam en de groepscode als aanvullende context. Gesprekken worden bij lezen opnieuw geprojecteerd; er is geen opgeslagen naamkopie die een herlaadactie overleeft. Identificatie en toegangscontrole blijven op de oorspronkelijke account-, gesprek- en onderwerp-ID's gebaseerd.

Dezelfde resolver wordt gebruikt door inschrijvings-, samenloop-, groepsindelings-, betaal- en profielprojecties. In de mailcatalogus zijn persoonsbegroetingen en groepslabels gescheiden. Samenloopmails gebruiken neutrale formuleringen en tonen het samenloopnummer en de wandelgroep afzonderlijk. Nieuwe groeps- en gespreksmails krijgen de naam van hun eigen ontvanger; de worker behoudt deze bij het veilig opnieuw opbouwen van een starttijdpayload.

De migratie bevat geen profielcorrectie, backfill of update van bestaande mailpayloads. Ontvangers, groepsindeling, samenlopen, gespreksrelaties en berichtinhoud blijven behouden. Een beperkte inserttrigger verrijkt alleen drie nieuwe groepsmailtypen. De private helpers hebben een vaste lege `search_path`; bestaande publieke RPC-autorisatie blijft behouden.

## Bewijs en regressies

Voor uitrol zijn hashes vastgelegd van de drie voorbeeldprofielen en gespreksrelaties, de negen bestaande berichten en beide samenloopmails. Het gecontroleerde dossier staat uitsluitend in de genegeerde private exportmap. Na uitrol worden dezelfde records vergeleken en wordt met zuivere projecties vastgesteld dat de drie persoonsnamen exact overeenkomen met hun geregistreerde bron, met de groepscode in een apart veld. Operationele uitvoer bevat alleen aantallen, foutcodes en correlatie-ID's.

Unit-, pgTAP- en browserregressies dekken de dubbele labels G-28/G-02/G-11, de G-46-samenloopmail, meerdere gezelschappen, echte afzenders, ontbrekende namen, gelijknamige afzonderlijke accounts, oude gesprekken na groepswisseling/samenvoeging en schrijfwijzen met accenten. De browserproeven controleren de inbox en definitieve mail-HTML op desktop en mobiel. De bestaande startplannings-, mailgateway-, backup-/herstel- en releasecontroles blijven verplicht. Alleen de reeds afgesproken mailbox-ontvangstproef is vrijgesteld bij de staginguitrol.

Tijdens de volledige regressiecontrole verstreek het vaste stemvenster van een bestaande lokale testfixture. De SQL- en concurrencyproeven krijgen daarom hun eigen toekomstige testdeadlines; de productie-instellingen en de proeven voor gesloten of verlopen stemvensters veranderen niet.
